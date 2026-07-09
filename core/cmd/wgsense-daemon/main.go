// wgsense-daemon 是 WgSense 的桌面守护进程。
// 后台常驻，执行智能管理策略，通过本地 HTTP API 与原生 UI 通信。
package main

import (
	"context"
	"flag"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	"github.com/wgsense/core/api"
	"github.com/wgsense/core/internal/config"
	"github.com/wgsense/core/internal/healthcheck"
	"github.com/wgsense/core/internal/location"
	"github.com/wgsense/core/internal/pause"
	"github.com/wgsense/core/internal/policy"
	"github.com/wgsense/core/internal/tunnel"
)

func main() {
	apiAddr := flag.String("api", "127.0.0.1:8765", "API 监听地址")
	configDir := flag.String("config-dir", "", "配置目录（默认 ~/.local/share/wgsense/profiles）")
	flag.Parse()

	cfg := config.Default()

	// 运行时状态目录
	rtDir := runtimeDir()
	pauseFile := filepath.Join(rtDir, "pause-marker")

	// 配置目录(放 .conf profile)
	cDir := *configDir
	if cDir == "" {
		cDir = filepath.Join(rtDir, "profiles")
	}
	os.MkdirAll(cDir, 0755)

	loc := location.New()
	tun := tunnel.New(cDir)
	hc := healthcheck.New(cfg.HealthCheckTarget)
	p := pause.New(pauseFile)
	eng := policy.New(cfg, loc, tun, hc, p)
	eng.SetService("default") // 默认 profile，可从 /api/profiles 选

	// 后台启动策略引擎守护循环
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() {
		if err := eng.Start(ctx); err != nil {
			log.Printf("引擎退出: %v", err)
		}
	}()

	// 信号处理
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		log.Println("收到退出信号")
		cancel()
		os.Exit(0)
	}()

	// 前台启动 API server
	log.Printf("WgSense daemon 启动 interval=%ds api=%s", cfg.IntervalSeconds, *apiAddr)
	apiSrv := api.New(*apiAddr, eng)
	if err := apiSrv.Start(); err != nil {
		log.Fatal(err)
	}
}

// runtimeDir 返回运行时状态目录。
func runtimeDir() string {
	home, _ := os.UserHomeDir()
	dir := filepath.Join(home, ".local", "share", "wgsense")
	os.MkdirAll(dir, 0755)
	return dir
}
