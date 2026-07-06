// Package tunnel 的 macOS 实现:基于 wireguard-go + utun。
// 注意:CreateTUN 和配置 IP/路由需要 root，开发阶段用 sudo 跑 daemon。
// 阶段 1 后期迁移到 NetworkExtension 后不再需要 root。
package tunnel

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"

	"github.com/wgsense/core/internal/config"
)

type darwinManager struct {
	dev       *device.Device
	tunName   string
	configDir string
}

func newPlatformManager(configDir string) Manager {
	return &darwinManager{configDir: configDir}
}

// ConnectWithProfile 用配置 profile 启动 WG 隧道(wireguard-go + utun)。
// 需要 root(CreateTUN + ifconfig + route)。
func (m *darwinManager) ConnectWithProfile(profile *config.Profile) error {
	// 1. 创建 TUN
	tunDev, err := tun.CreateTUN("utun", profile.Interface.MTU)
	if err != nil {
		return fmt.Errorf("创建 TUN: %w", err)
	}
	m.tunName, _ = tunDev.Name()

	// 2. 创建 WG 设备
	logger := device.NewLogger(device.LogLevelError, "wgsense")
	m.dev = device.NewDevice(tunDev, conn.NewDefaultBind(), logger)

	// 3. IPC 配置
	if err := m.dev.IpcSet(buildUAPI(profile)); err != nil {
		m.dev.Close()
		m.dev = nil
		return fmt.Errorf("IPC 配置: %w", err)
	}

	// 4. 启动 UDP
	if err := m.dev.BindUpdate(); err != nil {
		m.dev.Close()
		m.dev = nil
		return fmt.Errorf("BindUpdate: %w", err)
	}

	// 5. 配置 TUN IP + 路由(需 root)
	if profile.Interface.Address != "" {
		if err := configureInterface(m.tunName, profile.Interface.Address); err != nil {
			return fmt.Errorf("配置 TUN IP: %w", err)
		}
	}
	for _, peer := range profile.Peers {
		for _, cidr := range peer.AllowedIPs {
			if err := addRoute(cidr, m.tunName); err != nil {
				return fmt.Errorf("添加路由 %s: %w", cidr, err)
			}
		}
	}
	return nil
}

// Connect 按 service 名连接:从 configDir 加载 {service}.conf → ConnectWithProfile。
func (m *darwinManager) Connect(service string) error {
	confPath := filepath.Join(m.configDir, service+".conf")
	profile, err := config.ParseFile(confPath)
	if err != nil {
		return fmt.Errorf("加载配置 %s: %w", confPath, err)
	}
	return m.ConnectWithProfile(profile)
}

func (m *darwinManager) Disconnect(service string) error {
	if m.dev != nil {
		m.dev.Close()
		m.dev = nil
	}
	return nil
}

func (m *darwinManager) Status(service string) (State, error) {
	if m.dev == nil {
		return StateDisconnected, nil
	}
	return StateConnected, nil
}

// DiscoverServices 扫描 configDir 的 .conf 文件，返回 profile 名列表。
func (m *darwinManager) DiscoverServices() ([]string, error) {
	entries, err := os.ReadDir(m.configDir)
	if err != nil {
		return nil, err
	}
	var services []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".conf") {
			services = append(services, strings.TrimSuffix(e.Name(), ".conf"))
		}
	}
	return services, nil
}

// configureInterface 用 ifconfig 设置 TUN 的 IP 地址(需 root)。
func configureInterface(name, address string) error {
	ip, mask, err := parseCIDR(address)
	if err != nil {
		return err
	}
	cmd := exec.Command("ifconfig", name, "inet", ip, ip, "prefixlen", mask)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("ifconfig 失败: %s: %w", strings.TrimSpace(string(out)), err)
	}
	return nil
}

// addRoute 用 route add 添加路由到 TUN(需 root)。支持 IPv4 和 IPv6。
func addRoute(cidr, dev string) error {
	var cmd *exec.Cmd
	if strings.Contains(cidr, ":") {
		cmd = exec.Command("route", "-n", "add", "-inet6", cidr, "-interface", dev)
	} else {
		cmd = exec.Command("route", "-n", "add", "-net", cidr, "-interface", dev)
	}
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("route add 失败: %s: %w", strings.TrimSpace(string(out)), err)
	}
	return nil
}

func parseCIDR(cidr string) (ip, mask string, err error) {
	parts := strings.SplitN(cidr, "/", 2)
	if len(parts) != 2 {
		return "", "", fmt.Errorf("无效 CIDR: %s", cidr)
	}
	return parts[0], parts[1], nil
}
