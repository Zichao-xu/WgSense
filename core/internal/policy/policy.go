// Package policy 是智能管理策略引擎，整合 location/tunnel/healthcheck/pause。
// 对应 bash 守护的 run_once + daemon 循环，但跨平台、带假连接检测。
package policy

import (
	"context"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/wgsense/core/internal/config"
	"github.com/wgsense/core/internal/healthcheck"
	"github.com/wgsense/core/internal/location"
	"github.com/wgsense/core/internal/logbuf"
	"github.com/wgsense/core/internal/pause"
	"github.com/wgsense/core/internal/tunnel"
)

// Engine 智能管理引擎。
type Engine struct {
	cfg             config.Config
	loc             location.Locator
	tun             tunnel.Manager
	hc              healthcheck.Checker
	pause           pause.Controller
	service         string
	passive         bool
	appOwned        bool
	lastAutoUp      time.Time
	lastHealthCheck time.Time
	healthFailures  int
	autoFailures    int
	nextAutoAttempt time.Time

	// 日志缓冲（供 /api/logs 使用）
	LogBuf *logbuf.Buffer

	// 流量统计
	trafficMu   sync.RWMutex
	lastTxBytes uint64
	lastRxBytes uint64
	lastTxTime  time.Time
	txSpeed     float64 // bytes/sec
	rxSpeed     float64 // bytes/sec
}

// New 创建引擎。
func New(cfg config.Config, loc location.Locator, tun tunnel.Manager, hc healthcheck.Checker, p pause.Controller) *Engine {
	cfg.Normalize()
	return &Engine{
		cfg:    cfg,
		loc:    loc,
		tun:    tun,
		hc:     hc,
		pause:  p,
		LogBuf: logbuf.New(200),
	}
}

// SetService 设置当前管理的隧道/profile 名。
func (e *Engine) SetService(s string) { e.service = s }

// SetPassive marks an API-only engine that must never create a tunnel.
func (e *Engine) SetPassive(passive bool) { e.passive = passive }

// SetAppOwned marks a daemon that was started for the current GUI app session.
func (e *Engine) SetAppOwned(appOwned bool) { e.appOwned = appOwned }

// RunOnce 执行一次巡检。
// 逻辑：
//   - 受信任网络 → 断开 WG
//   - 非受信任网络 + 已暂停 → 跳过
//   - 非受信任网络 + Disconnected + AutoConnectUntrusted → 自动连上
//   - 非受信任网络 + Connected → 假连接检测，失效则强制 stop/start
func (e *Engine) RunOnce() error {
	// 暂停时跳过所有自动管理（包括可信网络断开、非可信网络连接、假连接检测）
	if e.pause.IsPaused() {
		state, _ := e.tun.Status(e.service)
		e.Logf("巡检 trusted=%v state=%s service=%s（已暂停，跳过）",
			e.loc.IsHome(e.cfg.TrustedNetworkPrefixes), state, e.service)
		return nil
	}

	trusted := e.loc.IsHome(e.cfg.TrustedNetworkPrefixes)
	state, _ := e.tun.Status(e.service)
	e.Logf("巡检 trusted=%v state=%s service=%s", trusted, state, e.service)

	// 受信任网络 → 断开
	if trusted {
		if state != tunnel.StateDisconnected {
			e.Logf("命中受信任网络，断开 WireGuard")
			return e.tun.Disconnect(e.service)
		}
		return nil
	}

	// 非受信任网络：根据隧道状态处理
	switch state {
	case tunnel.StateDisconnected:
		e.healthFailures = 0
		if !e.cfg.AutoConnectUntrusted {
			e.Logf("当前网络不在受信任前缀内，自动连接未启用")
			return nil
		}
		if e.recentAutoUp() {
			e.Logf("刚自动拉起，等待连接建立")
			return nil
		}
		if !e.nextAutoAttempt.IsZero() && time.Now().Before(e.nextAutoAttempt) {
			e.Logf("自动连接退避中，等待下次尝试")
			return nil
		}
		e.Logf("当前网络不在受信任前缀内，自动连接 WireGuard")
		if err := e.tun.Connect(e.service); err != nil {
			e.recordAutoFailure()
			return err
		}
		e.autoFailures = 0
		e.nextAutoAttempt = time.Time{}
		e.lastAutoUp = time.Now()

	case tunnel.StateConnected:
		// 假连接检测（bash 守护没做的）
		// 刚连接后给 15 秒握手宽限期，不要立刻判定假连接
		if e.recentAutoUp() {
			e.Logf("刚连接，等待握手（跳过假连接检测）")
			return nil
		}
		if !e.healthCheckDue() {
			return nil
		}
		e.lastHealthCheck = time.Now()
		if e.hc.IsStaleConnected(true) {
			e.healthFailures++
			e.Logf("隧道连通性探测失败（%d/3）", e.healthFailures)
		} else {
			e.healthFailures = 0
		}
		if e.healthFailures >= 3 {
			e.Logf("连续 3 次探测失败，重启隧道")
			_ = e.tun.Disconnect(e.service)
			if err := e.tun.Connect(e.service); err != nil {
				return err
			}
			e.lastAutoUp = time.Now()
			e.healthFailures = 0
		}
	}
	return nil
}

func (e *Engine) recordAutoFailure() {
	e.autoFailures++
	delay := time.Duration(30) * time.Second
	switch {
	case e.autoFailures >= 5:
		delay = 10 * time.Minute
	case e.autoFailures >= 3:
		delay = 5 * time.Minute
	case e.autoFailures >= 2:
		delay = 2 * time.Minute
	}
	e.nextAutoAttempt = time.Now().Add(delay)
	e.Logf("自动连接失败（%d），退避 %s", e.autoFailures, delay)
}

func (e *Engine) healthCheckDue() bool {
	interval := e.cfg.HealthCheckIntervalSeconds
	if interval <= 0 {
		interval = 30
	}
	return e.lastHealthCheck.IsZero() || time.Since(e.lastHealthCheck) >= time.Duration(interval)*time.Second
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
		e.Logf("巡检错误: %v", err)
	}

	for {
		select {
		case <-ticker.C:
			if err := e.RunOnce(); err != nil {
				e.Logf("巡检错误: %v", err)
			}
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

// StatusSnapshot 是当前状态快照，供 UI 查询。
type StatusSnapshot struct {
	TrustedNetwork       bool   `json:"trusted_network"`
	AtHome               bool   `json:"at_home"`
	State                string `json:"state"`
	Paused               bool   `json:"paused"`
	Service              string `json:"service"`
	Passive              bool   `json:"passive"`
	AutoConnectUntrusted bool   `json:"auto_connect_untrusted"`
	Auto                 bool   `json:"auto_connect_away"`
	AppOwned             bool   `json:"app_owned"`
}

// Status 返回当前状态快照。
func (e *Engine) Status() StatusSnapshot {
	state, _ := e.tun.Status(e.service)
	trusted := e.loc.IsHome(e.cfg.TrustedNetworkPrefixes)
	return StatusSnapshot{
		TrustedNetwork:       trusted,
		AtHome:               trusted,
		State:                string(state),
		Paused:               e.pause.IsPaused(),
		Service:              e.service,
		Passive:              e.passive,
		AutoConnectUntrusted: e.cfg.AutoConnectUntrusted,
		Auto:                 e.cfg.AutoConnectUntrusted,
		AppOwned:             e.appOwned,
	}
}

// Connect 手动连接隧道。
func (e *Engine) Connect() error {
	if e.passive {
		return fmt.Errorf("daemon 处于被动模式，WireGuard 连接需要正式网络服务")
	}
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
	if err := e.pause.Resume(); err != nil {
		return err
	}
	// 用户重新开启守护后立即应用网络策略，避免等待下一个巡检周期。
	return e.RunOnce()
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

// GetConfig 返回当前运行配置。
func (e *Engine) GetConfig() config.Config {
	return e.cfg
}

// UpdateConfig 更新运行配置（热更新，不需要重启 daemon）。
func (e *Engine) UpdateConfig(cfg config.Config) error {
	cfg.Normalize()
	// 确保必要字段有合理值
	if cfg.IntervalSeconds <= 0 {
		cfg.IntervalSeconds = 10
	}
	if cfg.AutoUpGraceSeconds <= 0 {
		cfg.AutoUpGraceSeconds = 20
	}
	if cfg.HealthCheckTarget == "" {
		cfg.HealthCheckTarget = "https://1.1.1.1"
	}
	if cfg.HealthCheckIntervalSeconds <= 0 {
		cfg.HealthCheckIntervalSeconds = 30
	}
	e.cfg = cfg
	e.hc = healthcheck.New(cfg.HealthCheckTarget)
	e.lastHealthCheck = time.Time{}
	e.healthFailures = 0
	e.autoFailures = 0
	e.nextAutoAttempt = time.Time{}
	e.Logf("配置已更新: 间隔=%ds 宽限=%ds 探测=%s 受信任网络前缀=%v 自动连接非受信任网络=%t",
		cfg.IntervalSeconds, cfg.AutoUpGraceSeconds, cfg.HealthCheckTarget, cfg.TrustedNetworkPrefixes, cfg.AutoConnectUntrusted)
	return nil
}

// Logf 写日志到标准输出 + 缓冲区。
func (e *Engine) Logf(format string, args ...interface{}) {
	line := fmt.Sprintf(format, args...)
	log.Println(line)
	e.LogBuf.WriteLine(line)
}

// Logs 返回最近 n 行日志。
func (e *Engine) Logs(n int) []string {
	return e.LogBuf.LastN(n)
}

// TrafficSnapshot 是流量统计快照。
type TrafficSnapshot struct {
	TxSpeed float64 `json:"tx_speed"` // 上行 bytes/sec
	RxSpeed float64 `json:"rx_speed"` // 下行 bytes/sec
	TxBytes uint64  `json:"tx_bytes"` // 累计上行
	RxBytes uint64  `json:"rx_bytes"` // 累计下行
}

// TrafficStats 返回当前流量统计（通过 utun 接口读取）。
func (e *Engine) TrafficStats() TrafficSnapshot {
	e.trafficMu.RLock()
	defer e.trafficMu.RUnlock()
	return TrafficSnapshot{
		TxSpeed: e.txSpeed,
		RxSpeed: e.rxSpeed,
		TxBytes: e.lastTxBytes,
		RxBytes: e.lastRxBytes,
	}
}

// UpdateTraffic 从 tun 接口读取最新字节数并计算速度。
func (e *Engine) UpdateTraffic() {
	tx, rx := e.tun.InterfaceBytes(e.service)
	now := time.Now()

	e.trafficMu.Lock()
	defer e.trafficMu.Unlock()

	if !e.lastTxTime.IsZero() {
		dt := now.Sub(e.lastTxTime).Seconds()
		if dt > 0 {
			if tx >= e.lastTxBytes {
				e.txSpeed = float64(tx-e.lastTxBytes) / dt
			}
			if rx >= e.lastRxBytes {
				e.rxSpeed = float64(rx-e.lastRxBytes) / dt
			}
		}
	}
	e.lastTxBytes = tx
	e.lastRxBytes = rx
	e.lastTxTime = now
}
