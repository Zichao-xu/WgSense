// Package tunnel 的 macOS 实现:基于 wireguard-go + utun。
// 注意:CreateTUN 和配置 IP/路由需要 root，开发阶段用 sudo 跑 daemon。
// 阶段 1 后期迁移到 NetworkExtension 后不再需要 root。
package tunnel

import (
	"fmt"
	"os/exec"
	"strings"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"

	"github.com/wgsense/core/internal/config"
)

type darwinManager struct {
	dev     *device.Device
	tunName string
}

func newPlatformManager() Manager {
	return &darwinManager{}
}

// ConnectWithProfile 用配置 profile 启动 WG 隧道(wireguard-go + utun)。
// 这是阶段 1 核心实现。需要 root(CreateTUN + ifconfig + route)。
func (m *darwinManager) ConnectWithProfile(profile *config.Profile) error {
	// 1. 创建 TUN(macOS utun，需 root)
	tunDev, err := tun.CreateTUN("utun", profile.Interface.MTU)
	if err != nil {
		return fmt.Errorf("创建 TUN: %w", err)
	}
	m.tunName, _ = tunDev.Name()

	// 2. 创建 WG 设备
	logger := device.NewLogger(device.LogLevelError, "wgsense")
	m.dev = device.NewDevice(tunDev, conn.NewDefaultBind(), logger)

	// 3. IPC 配置(private key / peers / endpoint / allowedIPs)
	if err := m.dev.IpcSet(buildUAPI(profile)); err != nil {
		m.dev.Close()
		m.dev = nil
		return fmt.Errorf("IPC 配置: %w", err)
	}

	// 4. 启动 UDP 监听
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

// Connect 按 service 名连接(阶段 1:从配置目录加载 profile)。
func (m *darwinManager) Connect(service string) error {
	return fmt.Errorf("Connect(service) 待实现:用 ConnectWithProfile，配置管理完善后接入")
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
	// TODO: 更精确的状态(wireguard-go 没有直接暴露 Connected 状态)
	return StateConnected, nil
}

func (m *darwinManager) DiscoverServices() ([]string, error) {
	// 阶段 1:扫描配置目录的 .conf 文件
	return nil, nil
}

// configureInterface 用 ifconfig 设置 TUN 的 IP 地址(需 root)。
// address 格式 10.0.0.2/24，macOS: ifconfig utunN inet 10.0.0.2 10.0.0.2 prefixlen 24
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

// addRoute 用 route add 添加路由到 TUN(需 root)。
// macOS: route -n add -net <cidr> -interface <dev>
func addRoute(cidr, dev string) error {
	cmd := exec.Command("route", "-n", "add", "-net", cidr, "-interface", dev)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("route add 失败: %s: %w", strings.TrimSpace(string(out)), err)
	}
	return nil
}

// parseCIDR 把 10.0.0.2/24 拆成 ip 和 prefixlen。
func parseCIDR(cidr string) (ip, mask string, err error) {
	parts := strings.SplitN(cidr, "/", 2)
	if len(parts) != 2 {
		return "", "", fmt.Errorf("无效 CIDR: %s", cidr)
	}
	return parts[0], parts[1], nil
}
