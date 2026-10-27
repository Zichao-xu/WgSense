package tunnel

import (
	"encoding/json"
	"fmt"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
)

// IPv6 模式。
const (
	IPv6ModeAuto  = "auto"  // 有就用：探测隧道 IPv6 能出网就走隧道，不能就拒绝
	IPv6ModeBlock = "block" // 始终拒绝公网 IPv6，程序全部改用 IPv4 进隧道
)

// IPv6 当前状态。
const (
	IPv6StateTunnel    = "tunnel"    // 公网 IPv6 走隧道
	IPv6StateBlocked   = "blocked"   // 公网 IPv6 被拒绝，程序改用 IPv4 进隧道
	IPv6StateProbing   = "probing"   // 已拒绝，正在探测隧道 IPv6
	IPv6StateUntouched = "untouched" // 分流配置或未连接：不接管 IPv6
)

// IPv6Settings 是全局隧道的公网 IPv6 设置，单独持久化，修改即时生效。
type IPv6Settings struct {
	Mode string `json:"mode"`
	// Prefix 是隧道 IPv6 地址约定：前缀 + 隧道 IPv4，如 fd77:6773:: + 10.66.66.3。
	// 服务器开 IPv6 时按同一约定配地址即可，本机不用写进配置。下次连接生效。
	Prefix string `json:"prefix"`
	// ProbeTargets 经隧道探测 IPv6 能否出网的地址（[IPv6]:端口），任一连通即算有。
	ProbeTargets []string `json:"probe_targets"`
}

// DefaultIPv6Settings 返回默认设置。
func DefaultIPv6Settings() IPv6Settings {
	return IPv6Settings{
		Mode:   IPv6ModeAuto,
		Prefix: "fd77:6773::",
		ProbeTargets: []string{
			"[2400:3200::1]:53",         // 阿里 DNS
			"[2402:4e00::]:53",          // 腾讯 DNSPod
			"[2001:4860:4860::8888]:53", // Google DNS
		},
	}
}

// Normalized 用默认值补齐空字段。
func (s IPv6Settings) Normalized() IPv6Settings {
	d := DefaultIPv6Settings()
	if s.Mode == "" {
		s.Mode = d.Mode
	}
	if strings.TrimSpace(s.Prefix) == "" {
		s.Prefix = d.Prefix
	}
	if len(s.ProbeTargets) == 0 {
		s.ProbeTargets = d.ProbeTargets
	}
	return s
}

// Validate 检查设置是否可用。
func (s IPv6Settings) Validate() error {
	if s.Mode != IPv6ModeAuto && s.Mode != IPv6ModeBlock {
		return fmt.Errorf("未知的 IPv6 模式: %q", s.Mode)
	}
	if _, err := deriveIPv6(s.Prefix, netip.MustParseAddr("10.0.0.1")); err != nil {
		return err
	}
	for _, target := range s.ProbeTargets {
		host, port, err := net.SplitHostPort(target)
		if err != nil || port == "" {
			return fmt.Errorf("探测地址需写成 [IPv6]:端口: %q", target)
		}
		if addr, err := netip.ParseAddr(host); err != nil || !addr.Is6() || addr.Is4In6() {
			return fmt.Errorf("探测地址不是 IPv6: %q", target)
		}
	}
	return nil
}

// deriveIPv6 按约定拼出隧道 IPv6 地址。
func deriveIPv6(prefix string, v4 netip.Addr) (netip.Addr, error) {
	prefix = strings.TrimSpace(prefix)
	if !strings.HasSuffix(prefix, "::") {
		return netip.Addr{}, fmt.Errorf("前缀需以 :: 结尾，如 fd77:6773::")
	}
	addr, err := netip.ParseAddr(prefix + v4.String())
	if err != nil || !addr.Is6() || addr.Is4In6() {
		return netip.Addr{}, fmt.Errorf("前缀无效: %q", prefix)
	}
	if !addr.IsPrivate() {
		return netip.Addr{}, fmt.Errorf("前缀需在私有地址段 fc00::/7 内: %q", prefix)
	}
	return addr, nil
}

// LoadIPv6Settings 读取设置；文件不存在或损坏时用默认值。
func LoadIPv6Settings(path string) IPv6Settings {
	var s IPv6Settings
	if data, err := os.ReadFile(path); err == nil {
		_ = json.Unmarshal(data, &s)
	}
	s = s.Normalized()
	if s.Validate() != nil {
		return DefaultIPv6Settings()
	}
	return s
}

// SaveIPv6Settings 原子写入设置。
func SaveIPv6Settings(path string, s IPv6Settings) error {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(data, '\n'), 0600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// Coverage 说明隧道实际接管了什么、哪些流量不走隧道以及原因，供界面展示。
type Coverage struct {
	FullTunnel bool         `json:"full_tunnel"`
	IPv6       IPv6Status   `json:"ipv6"`
	Bypass     []BypassPath `json:"bypass,omitempty"`
	DNS        []string     `json:"dns,omitempty"`
	DNSService string       `json:"dns_service,omitempty"`
}

// IPv6Status 是公网 IPv6 的当前处理方式。
type IPv6Status struct {
	Mode        string   `json:"mode"`
	State       string   `json:"state"`
	Address     string   `json:"address,omitempty"`    // 隧道 IPv6 地址
	Derived     bool     `json:"derived,omitempty"`    // 地址按约定推出（而非配置里写的）
	LastProbe   string   `json:"last_probe,omitempty"` // RFC3339
	LastProbeOK bool     `json:"last_probe_ok"`        //
	NextProbe   string   `json:"next_probe,omitempty"` // RFC3339
	Targets     []string `json:"targets,omitempty"`    // 探测地址
	Error       string   `json:"error,omitempty"`      // 路由安装失败
}

// BypassPath 是一条不走隧道的路径。
type BypassPath struct {
	Destination string `json:"destination"`
	Via         string `json:"via"`
	Reason      string `json:"reason"`
}

// CoverageProvider 由能报告隧道覆盖范围的平台实现。
type CoverageProvider interface {
	Coverage(service string) Coverage
	// Endpoints 返回当前隧道实际使用的 WG 服务器地址（未连接时为空）。
	Endpoints() []string
}

// IPv6Configurable 由支持公网 IPv6 设置的平台实现。
type IPv6Configurable interface {
	IPv6Settings() IPv6Settings
	SetIPv6Settings(IPv6Settings) error
}

// StateNotifier 在隧道建立或拆除后回调，让出站拦截等立即跟上隧道状态。
type StateNotifier interface {
	SetStateHook(func())
}
