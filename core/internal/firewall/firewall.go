// Package firewall 是基于整台电脑(pf + hosts)的出站拦截，与 WireGuard 链路无关。
//
// 两种触发：
//   - 自动：不在受信任网络时拦截从物理网卡直出的流量。走 WG 隧道的流量不受影响，
//     所以 WG 断线、重连空窗、假连接期间漏出去的直连都会被挡住。
//   - 国内模式(强制)：无论什么网络、无论是否走隧道，一律拦截。
//
// 两档范围：仅 AI 服务 / 全部境外(只放行国内 IP、局域网和 WG 服务器)。
//
// 规则是 fail-closed 的：daemon 退出不清理，只有用户关闭开关、卸载服务或
// 执行 `wgsense-daemon --firewall-clear` 才会解除。
package firewall

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// StateDir 存放 pf 规则、国内段表和 pf 启用令牌(root 持有，跨用户目录不变)。
var StateDir = "/Library/Application Support/WgSense/firewall"

// CNTablePath 是国内 IP 段表文件位置。
func CNTablePath() string { return filepath.Join(StateDir, "cn.txt") }

// Level 是拦截范围。
type Level string

const (
	LevelAI      Level = "ai"
	LevelForeign Level = "foreign"
)

// Settings 是用户可改的拦截设置，单独持久化，避免被 /api/config 的整包同步覆盖。
type Settings struct {
	// AutoBlock 不在受信任网络时自动拦截物理网卡直出流量。
	AutoBlock bool `json:"auto_block"`
	// ForceDomestic 国内模式：任何网络、任何出口都拦截。
	ForceDomestic bool `json:"force_domestic"`
	// Level 拦截范围。
	Level Level `json:"level"`
	// AIDomains 为空时使用内置名单。
	AIDomains []string `json:"ai_domains"`
}

// Observation 是策略引擎每轮巡检提供的网络状态。
type Observation struct {
	Trusted  bool
	TunnelUp bool // WG 已连接且健康探测没有失败
}

// Status 是当前实际生效情况，供 UI 展示。
type Status struct {
	Active     bool     `json:"active"`
	Forced     bool     `json:"forced"`
	Level      Level    `json:"level"`
	Reason     string   `json:"reason"`
	Interfaces []string `json:"interfaces,omitempty"`
	HostsBlock bool     `json:"hosts_block"`
	Error      string   `json:"error,omitempty"`
	UpdatedAt  string   `json:"updated_at,omitempty"`
}

// Backend 执行真正的系统修改；测试里替换为假实现。
type Backend interface {
	ApplyPF(rules string) error
	ClearPF() error
	ApplyHosts(domains []string) error // nil 表示移除 WgSense 段
}

// Controller 根据设置和网络状态维护 pf 锚点与 hosts。
type Controller struct {
	mu       sync.Mutex
	path     string
	settings Settings
	backend  Backend
	logf     func(string, ...interface{})

	// 依赖探测，测试可替换。
	PhysicalInterfaces func() []string
	TunnelEndpoints    func() []string
	OtherVPNActive     func() bool

	lastObs      Observation
	haveObs      bool
	appliedPF    string
	appliedHosts string
	synced       bool
	status       Status
}

// DefaultSettings 返回默认设置(全部关闭，用户在 App 里打开)。
func DefaultSettings() Settings {
	return Settings{Level: LevelAI}
}

// Normalize 补默认值并整理域名。
func (s *Settings) Normalize() {
	if s.Level != LevelForeign {
		s.Level = LevelAI
	}
	s.AIDomains = normalizeDomains(s.AIDomains)
}

// EffectiveAIDomains 返回实际使用的 AI 域名名单。
func (s Settings) EffectiveAIDomains() []string {
	if len(s.AIDomains) == 0 {
		return DefaultAIDomains()
	}
	return s.AIDomains
}

// New 读取 path 的设置并创建控制器。logf 可为 nil。
func New(path string, backend Backend, logf func(string, ...interface{})) *Controller {
	if logf == nil {
		logf = func(string, ...interface{}) {}
	}
	c := &Controller{
		path:               path,
		settings:           DefaultSettings(),
		backend:            backend,
		logf:               logf,
		PhysicalInterfaces: physicalInterfaces,
		TunnelEndpoints:    func() []string { return nil },
		OtherVPNActive:     func() bool { return false },
	}
	if path != "" {
		if data, err := os.ReadFile(path); err == nil {
			var saved Settings
			if json.Unmarshal(data, &saved) == nil {
				c.settings = saved
			} else {
				logf("读取拦截设置失败，使用默认值: %s", path)
			}
		}
	}
	c.settings.Normalize()
	return c
}

// Settings 返回当前设置。
func (c *Controller) Settings() Settings {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.settings
}

// Status 返回当前生效状态。
func (c *Controller) Status() Status {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.status
}

// Update 保存新设置并按上一轮的网络状态立即生效。
func (c *Controller) Update(s Settings) error {
	s.Normalize()
	c.mu.Lock()
	defer c.mu.Unlock()
	if err := c.save(s); err != nil {
		return err
	}
	c.settings = s
	c.logf("拦截设置已更新: 自动=%t 国内模式=%t 范围=%s", s.AutoBlock, s.ForceDomestic, s.Level)
	if !c.haveObs {
		// 还没有网络状态时，只有强制模式能确定；自动模式等第一轮巡检。
		if !s.ForceDomestic && !s.AutoBlock {
			return c.applyLocked(plan{reason: "未开启拦截"})
		}
		if !s.ForceDomestic {
			return nil
		}
	}
	return c.syncLocked(c.lastObs)
}

// Sync 由策略引擎每轮巡检调用。只有规则内容变化时才触碰系统。
func (c *Controller) Sync(obs Observation) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.lastObs, c.haveObs = obs, true
	return c.syncLocked(obs)
}

func (c *Controller) save(s Settings) error {
	if c.path == "" {
		return nil
	}
	if err := os.MkdirAll(filepath.Dir(c.path), 0755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	tmp := c.path + ".tmp"
	if err := os.WriteFile(tmp, append(data, '\n'), 0600); err != nil {
		return err
	}
	return os.Rename(tmp, c.path)
}

type plan struct {
	active     bool
	forced     bool
	level      Level
	reason     string
	interfaces []string // 为空且 active 表示所有接口
	pf         string
	hosts      []string
}

func (c *Controller) decide(obs Observation) plan {
	s := c.settings
	p := plan{level: s.Level}
	switch {
	case s.ForceDomestic:
		p.active, p.forced, p.reason = true, true, "国内模式：所有出口均拦截"
	case !s.AutoBlock:
		p.reason = "未开启拦截"
		return p
	case obs.Trusted:
		p.reason = "受信任网络，由家中网关负责出口"
		return p
	case s.Level == LevelForeign && c.OtherVPNActive():
		// 境外档会挡住其他 VPN 的服务器；让出给它，流量走它的隧道接口。
		p.reason = "检测到其他系统 VPN，暂停境外拦截"
		return p
	default:
		p.active = true
		if obs.TunnelUp {
			p.reason = "非受信任网络：拦截物理网卡直连，WG 隧道放行"
		} else {
			p.reason = "非受信任网络且 WG 未连通：拦截直连"
		}
	}
	if !p.forced {
		p.interfaces = c.PhysicalInterfaces()
		if len(p.interfaces) == 0 {
			// 没有物理网卡就没有可漏的出口，规则留空。
			p.reason += "（当前无物理网卡）"
		}
	}
	if p.forced || len(p.interfaces) > 0 {
		in := RuleInput{Level: s.Level, Interfaces: p.interfaces, CNFile: CNTablePath()}
		if s.Level == LevelForeign {
			in.Endpoints = c.TunnelEndpoints()
		}
		p.pf = RenderPF(in)
	}
	// hosts 无法区分出口：隧道正常时写进去会连隧道一起挡，所以只在
	// 强制模式或隧道没连通时启用域名级拦截。
	if p.forced || !obs.TunnelUp {
		p.hosts = s.EffectiveAIDomains()
	}
	return p
}

func (c *Controller) syncLocked(obs Observation) error {
	return c.applyLocked(c.decide(obs))
}

func (c *Controller) applyLocked(p plan) error {
	hostsKey := strings.Join(p.hosts, ",")
	var errs []error
	if !c.synced || p.pf != c.appliedPF {
		var err error
		if p.pf == "" {
			err = c.backend.ClearPF()
		} else {
			err = c.backend.ApplyPF(p.pf)
		}
		if err != nil {
			errs = append(errs, fmt.Errorf("pf: %w", err))
		} else {
			c.appliedPF = p.pf
		}
	}
	if !c.synced || hostsKey != c.appliedHosts {
		var err error
		if len(p.hosts) == 0 {
			err = c.backend.ApplyHosts(nil)
		} else {
			err = c.backend.ApplyHosts(p.hosts)
		}
		if err != nil {
			errs = append(errs, fmt.Errorf("hosts: %w", err))
		} else {
			c.appliedHosts = hostsKey
		}
	}
	changed := !c.synced || c.status.Active != p.active || c.status.Reason != p.reason
	if len(errs) == 0 {
		c.synced = true
	}
	c.status = Status{
		Active:     p.active,
		Forced:     p.forced,
		Level:      p.level,
		Reason:     p.reason,
		Interfaces: p.interfaces,
		HostsBlock: len(p.hosts) > 0,
		UpdatedAt:  time.Now().Format(time.RFC3339),
	}
	err := errors.Join(errs...)
	if err != nil {
		c.status.Error = err.Error()
		c.logf("拦截规则应用失败: %v", err)
	} else if changed {
		if p.active {
			c.logf("拦截已生效(%s): %s 网卡=%v 域名拦截=%t", p.level, p.reason, p.interfaces, len(p.hosts) > 0)
		} else {
			c.logf("拦截已解除: %s", p.reason)
		}
	}
	return err
}

// ClearAll 无条件移除所有拦截(卸载/应急)。
func ClearAll(b Backend) error {
	return errors.Join(b.ClearPF(), b.ApplyHosts(nil))
}

func normalizeDomains(in []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, d := range in {
		d = strings.ToLower(strings.TrimSpace(d))
		d = strings.TrimPrefix(strings.TrimPrefix(d, "https://"), "http://")
		d = strings.TrimPrefix(d, "*.")
		if i := strings.IndexAny(d, "/:"); i >= 0 {
			d = d[:i]
		}
		d = strings.Trim(d, ".")
		if d == "" || !strings.Contains(d, ".") || strings.ContainsAny(d, " \t#") || seen[d] {
			continue
		}
		seen[d] = true
		out = append(out, d)
	}
	return out
}
