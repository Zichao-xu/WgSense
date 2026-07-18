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
	"time"

	"github.com/wgsense/core/api"
	"github.com/wgsense/core/internal/config"
	"github.com/wgsense/core/internal/healthcheck"
	"github.com/wgsense/core/internal/location"
	"github.com/wgsense/core/internal/pause"
	"github.com/wgsense/core/internal/policy"
	"github.com/wgsense/core/internal/proxy"
	"github.com/wgsense/core/internal/transfer"
	"github.com/wgsense/core/internal/tunnel"
)

func main() {
	apiAddr := flag.String("api", "127.0.0.1:8765", "API 监听地址")
	mihomoAddr := flag.String("mihomo", "10.10.1.1:9090", "Mihomo API 地址")
	mihomoSecret := flag.String("mihomo-secret", "", "Mihomo API 密钥")
	configDir := flag.String("config-dir", "", "配置目录（默认 ~/.local/share/wgsense/profiles）")
	runtimeDirOverride := flag.String("runtime-dir", "", "运行数据目录（授权启动时应指向登录用户目录）")
	downloadDir := flag.String("download-dir", "", "LocalSend 接收目录（正式 root 服务应显式指定登录用户目录）")
	passive := flag.Bool("passive", false, "被动模式：仅启动文件传输和本地 API，不运行 WireGuard 策略或 Mihomo")
	autoConnect := flag.Bool("auto-connect-untrusted", false, "当前网络不在受信任前缀内时自动连接 WireGuard（默认关闭）")
	autoConnectAway := flag.Bool("auto-connect-away", false, "兼容旧参数：非受信任网络自动连接 WireGuard")
	appOwned := flag.Bool("app-owned", false, "由当前 GUI App 临时启动；App 退出时允许通过 API 关闭")
	flag.Parse()

	cfg := config.Default()
	cfg.AutoConnectUntrusted = *autoConnect || *autoConnectAway
	cfg.Normalize()

	// 运行时状态目录
	rtDir := runtimeDir(*runtimeDirOverride)
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
	eng.SetPassive(*passive)
	eng.SetAppOwned(*appOwned)

	// 后台启动策略引擎守护循环
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// 传输服务（LocalSend 协议兼容）
	transSvc, err := transfer.New("WgSense-Mac", *downloadDir)
	if err != nil {
		log.Printf("传输服务初始化失败: %v", err)
		transSvc = nil
	} else {
		if err := transSvc.Start(ctx); err != nil {
			log.Printf("传输服务启动失败: %v", err)
			transSvc = nil
		} else {
			log.Println("传输服务已启动 (LocalSend 兼容)")
		}
	}

	// 代理控制器客户端只访问 Mihomo API，不修改本机路由；被动模式也可安全使用。
	proxyConfigPath := filepath.Join(rtDir, "proxy.json")
	proxyCfg, err := proxy.LoadConfig(proxyConfigPath)
	if err != nil {
		log.Printf("读取代理设置失败，使用默认值: %v", err)
		proxyCfg = proxy.DefaultConfig()
	}
	explicitFlags := map[string]bool{}
	flag.Visit(func(item *flag.Flag) { explicitFlags[item.Name] = true })
	if explicitFlags["mihomo"] {
		proxyCfg.Address = *mihomoAddr
	}
	if explicitFlags["mihomo-secret"] {
		proxyCfg.Secret = *mihomoSecret
	}
	proxySvc, err := proxy.NewPersistent(proxyCfg, proxyConfigPath)
	if err != nil {
		log.Printf("代理服务初始化失败: %v", err)
		proxySvc = nil
	} else if err := proxySvc.Start(); err != nil {
		log.Printf("代理服务启动失败(非致命): %v", err)
	}

	// 后台启动策略引擎守护循环
	if !*passive {
		go func() {
			if err := eng.Start(ctx); err != nil {
				log.Printf("引擎退出: %v", err)
			}
		}()
	} else {
		log.Println("被动模式已启用：WireGuard 策略未启动；Mihomo 仅启用远程控制器客户端")
	}

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
	log.Printf("WgSense daemon 启动 interval=%ds api=%s mihomo=%s passive=%t auto_connect_untrusted=%t app_owned=%t", cfg.IntervalSeconds, *apiAddr, *mihomoAddr, *passive, cfg.AutoConnectUntrusted, *appOwned)
	apiSrv := api.New(*apiAddr, eng, transSvc, proxySvc)
	if *appOwned {
		apiSrv.SetShutdown(func() {
			cancel()
			_ = eng.Disconnect()
			go func() {
				// Give the HTTP response a moment to flush before exiting.
				time.Sleep(200 * time.Millisecond)
				os.Exit(0)
			}()
		})
	}
	if err := apiSrv.Start(); err != nil {
		log.Fatal(err)
	}
}

// runtimeDir 返回运行时状态目录。
func runtimeDir(override string) string {
	if override != "" {
		dir, err := filepath.Abs(override)
		if err == nil {
			os.MkdirAll(dir, 0755)
			return dir
		}
	}
	home, _ := os.UserHomeDir()
	dir := filepath.Join(home, ".local", "share", "wgsense")
	os.MkdirAll(dir, 0755)
	return dir
}
