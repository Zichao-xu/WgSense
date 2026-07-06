// Package policy 是智能管理策略引擎，整合 location/tunnel/healthcheck/pause。
// 对应 bash 守护的 run_once + daemon 循环，但跨平台、带假连接检测。
package policy

import (
	"context"

	"github.com/wgsense/core/internal/config"
	"github.com/wgsense/core/internal/healthcheck"
	"github.com/wgsense/core/internal/location"
	"github.com/wgsense/core/internal/pause"
	"github.com/wgsense/core/internal/tunnel"
)

// Engine 智能管理引擎。
type Engine struct {
	cfg   config.Config
	loc   location.Locator
	tun   tunnel.Manager
	hc    healthcheck.Checker
	pause pause.Controller
}

// New 创建引擎。
func New(cfg config.Config, loc location.Locator, tun tunnel.Manager, hc healthcheck.Checker, p pause.Controller) *Engine {
	return &Engine{cfg: cfg, loc: loc, tun: tun, hc: hc, pause: p}
}

// RunOnce 执行一次巡检。
// 逻辑：
//   - 在家 → 断开 WG
//   - 不在家 + 已暂停 → 跳过
//   - 不在家 + Disconnected → 自动连上
//   - 不在家 + Connected → 假连接检测，失效则强制 stop/start
func (e *Engine) RunOnce() error {
	// 阶段 1 实现完整逻辑
	return nil
}

// Start 启动守护循环，每 IntervalSeconds 秒巡检一次。
func (e *Engine) Start(ctx context.Context) error {
	// 阶段 1 实现：ticker + RunOnce 循环
	<-ctx.Done()
	return ctx.Err()
}
