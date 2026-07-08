// Package policy 是智能管理策略引擎，整合 location/tunnel/healthcheck/pause。
// 对应 bash 守护的 run_once + daemon 循环，但跨平台、带假连接检测。
package policy

import (
	"context"
	"log"
	"time"

	"github.com/wgsense/core/internal/config"
	"github.com/wgsense/core/internal/healthcheck"
	"github.com/wgsense/core/internal/location"
	"github.com/wgsense/core/internal/pause"
	"github.com/wgsense/core/internal/tunnel"
)

// Engine 智能管理引擎。
type Engine struct {
	cfg        config.Config
	loc        location.Locator
	tun        tunnel.Manager
	hc         healthcheck.Checker
	pause      pause.Controller
	service    string
	lastAutoUp time.Time
}

// New 创建引擎。
func New(cfg config.Config, loc location.Locator, tun tunnel.Manager, hc healthcheck.Checker, p pause.Controller) *Engine {
	return &Engine{cfg: cfg, loc: loc, tun: tun, hc: hc, pause: p}
}

// SetService 设置当前管理的隧道/profile 名。
func (e *Engine) SetService(s string) { e.service = s }

// RunOnce 执行一次巡检。
// 逻辑：
//   - 在家 → 断开 WG
//   - 不在家 + 已暂停 → 跳过
//   - 不在家 + Disconnected → 自动连上
//   - 不在家 + Connected → 假连接检测，失效则强制 stop/start
func (e *Engine) RunOnce() error {
	// 暂停时跳过所有自动管理（包括在家断开、在外连接、假连接检测）
	if e.pause.IsPaused() {
		state, _ := e.tun.Status(e.service)
		log.Printf("巡检 at_home=%v state=%s service=%s（已暂停，跳过）",
			e.loc.IsHome(e.cfg.HomeNetworkPrefixes), state, e.service)
		return nil
	}

	atHome := e.loc.IsHome(e.cfg.HomeNetworkPrefixes)
	state, _ := e.tun.Status(e.service)
	log.Printf("巡检 at_home=%v state=%s service=%s", atHome, state, e.service)

	// 在家 → 断开
	if atHome {
		if state != tunnel.StateDisconnected {
			log.Println("命中家网段，断开 WireGuard")
			return e.tun.Disconnect(e.service)
		}
		return nil
	}

	// 不到家：根据隧道状态处理
	switch state {
	case tunnel.StateDisconnected:
		if e.recentAutoUp() {
			log.Println("刚自动拉起，等待连接建立")
			return nil
		}
		log.Println("不在家网段，自动连接 WireGuard")
		if err := e.tun.Connect(e.service); err != nil {
			return err
		}
		e.lastAutoUp = time.Now()

	case tunnel.StateConnected:
		// 假连接检测（bash 守护没做的）
		// 刚连接后给 15 秒握手宽限期，不要立刻判定假连接
		if e.recentAutoUp() {
			log.Println("刚连接，等待握手（跳过假连接检测）")
			return nil
		}
		if e.hc.IsStaleConnected(true) {
			log.Println("检测到假连接（Connected 但不通），强制重启隧道")
			_ = e.tun.Disconnect(e.service)
			if err := e.tun.Connect(e.service); err != nil {
				return err
			}
			e.lastAutoUp = time.Now()
		}
	}
	return nil
}

// recentAutoUp 判断是否刚自动拉起（在宽限期内）。
func (e *Engine) recentAutoUp() bool {
	if e.lastAutoUp.IsZero() {
		return false
	}
	return time.Since(e.lastAutoUp) < time.Duration(e.cfg.AutoUpGraceSeconds)*time.Second
}

// Start 启动守护循环，每 IntervalSeconds 秒巡检一次。
func (e *Engine) Start(ctx context.Context) error {
	ticker := time.NewTicker(time.Duration(e.cfg.IntervalSeconds) * time.Second)
	defer ticker.Stop()

	// 立即执行一次
	if err := e.RunOnce(); err != nil {
		log.Printf("巡检错误: %v", err)
	}

	for {
		select {
		case <-ticker.C:
			if err := e.RunOnce(); err != nil {
				log.Printf("巡检错误: %v", err)
			}
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

// StatusSnapshot 是当前状态快照，供 UI 查询。
type StatusSnapshot struct {
	AtHome  bool   `json:"at_home"`
	State   string `json:"state"`
	Paused  bool   `json:"paused"`
	Service string `json:"service"`
}

// Status 返回当前状态快照。
func (e *Engine) Status() StatusSnapshot {
	state, _ := e.tun.Status(e.service)
	return StatusSnapshot{
		AtHome:  e.loc.IsHome(e.cfg.HomeNetworkPrefixes),
		State:   string(state),
		Paused:  e.pause.IsPaused(),
		Service: e.service,
	}
}

// Connect 手动连接隧道。
func (e *Engine) Connect() error {
	return e.tun.Connect(e.service)
}

// Disconnect 手动断开隧道。
func (e *Engine) Disconnect() error {
	return e.tun.Disconnect(e.service)
}

// Pause 暂停自动管理。
func (e *Engine) Pause() error {
	return e.pause.Pause()
}

// Resume 恢复自动管理。
func (e *Engine) Resume() error {
	return e.pause.Resume()
}

// Profiles 返回可用 profile 列表(扫描配置目录)。
func (e *Engine) Profiles() []string {
	services, _ := e.tun.DiscoverServices()
	return services
}

// ConfigDir 返回配置目录路径。
func (e *Engine) ConfigDir() string {
	return e.tun.ConfigDir()
}

// ImportProfile 将 .conf 文本内容保存为新 profile。
func (e *Engine) ImportProfile(name, content string) error {
	return e.tun.SaveProfile(name, content)
}

// ExportProfile 读取指定 profile 的 .conf 文本内容。
func (e *Engine) ExportProfile(name string) (string, error) {
	return e.tun.LoadProfileContent(name)
}

// DeleteProfile 删除指定 profile。
func (e *Engine) DeleteProfile(name string) error {
	return e.tun.DeleteProfile(name)
}
