// Package tunnel 的 macOS 实现:基于 wireguard-go + utun。
// 注意:CreateTUN 和配置 IP/路由需要 root，开发阶段用 sudo 跑 daemon。
// 阶段 1 后期迁移到 NetworkExtension 后不再需要 root。
//
// 重要设计决策：
// 1. 不修改系统 DNS — 用 networksetup 改 DNS 在 daemon 异常退出时会残留，导致断网。
//    DNS 解析由 Go 的 netresolver 在应用层处理（走 TUN 或物理接口的 UDP 53）。
// 2. endpoint 排除路由在 BindUpdate 之前添加 — 确保 WG UDP 握手包走物理接口。
// 3. cleanup 注册 signal handler — 即使 kill -9 也能尝试清理路由。
package tunnel

import (
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun"

	"github.com/wgsense/core/internal/config"
)

type darwinManager struct {
	dev         *device.Device
	tunName     string
	configDir   string
	origGateway string        // 建隧道前的物理网关
	physIface   string        // 物理接口名（en0/en1）
	addedRoutes []routeEntry  // 已添加的路由（断开时清理）
	cleaned     bool          // 防止重复 cleanup
}

type routeEntry struct {
	cidr string
	gw   string // 网关 IP（空=interface 路由）
	dev  string // 接口名
}

func newPlatformManager(configDir string) Manager {
	return &darwinManager{configDir: configDir}
}

// ConnectWithProfile 用配置 profile 启动 WG 隧道(wireguard-go + utun)。
// 需要 root(CreateTUN + ifconfig + route)。
func (m *darwinManager) ConnectWithProfile(profile *config.Profile) error {
	// 重置 cleanup 标志，允许新一轮清理
	m.cleaned = false

	// 0. 获取物理网络信息（必须在路由表变更前）
	gw, err := getDefaultGateway()
	if err != nil {
		return fmt.Errorf("获取物理网关: %w", err)
	}
	m.origGateway = gw

	iface, err := getDefaultInterface()
	if err != nil {
		return fmt.Errorf("获取物理接口: %w", err)
	}
	m.physIface = iface
	log.Printf("[tunnel] 物理接口=%s 网关=%s", iface, gw)

	// 0.5 注册 signal handler，确保异常退出时清理路由
	m.setupSignalHandler()

	// 1. 解析 endpoint IP 并添加排除路由（在创建 TUN 之前，确保后续 UDP 包走物理接口）
	var endpointIP string
	for _, peer := range profile.Peers {
		if peer.Endpoint != "" {
			ip, err := resolveEndpoint(peer.Endpoint)
			if err != nil {
				return fmt.Errorf("解析 endpoint %s: %w", peer.Endpoint, err)
			}
			endpointIP = ip
			log.Printf("[tunnel] endpoint %s → %s", peer.Endpoint, ip)

			// endpoint 排除路由：走物理网关，不走隧道
			if err := m.addExclusionRoute(endpointIP, gw); err != nil {
				return fmt.Errorf("endpoint 排除路由 %s: %w", endpointIP, err)
			}
			break
		}
	}

	// 2. 添加本地网段排除路由（DNS 服务器、局域网设备不走隧道）
	if localNet, err := getLocalNetwork(); err == nil {
		if err := m.addExclusionRoute(localNet, ""); err != nil {
			log.Printf("[tunnel] 本地网段排除失败（非致命）: %v", err)
		} else {
			log.Printf("[tunnel] 本地网段排除: %s → %s", localNet, m.physIface)
		}
	}

	// 3. 创建 TUN
	tunDev, err := tun.CreateTUN("utun", profile.Interface.MTU)
	if err != nil {
		m.cleanup()
		return fmt.Errorf("创建 TUN: %w", err)
	}
	m.tunName, _ = tunDev.Name()
	log.Printf("[tunnel] TUN=%s 已创建", m.tunName)

	// 4. 创建 WG 设备
	logger := device.NewLogger(device.LogLevelVerbose, "wgsense")
	m.dev = device.NewDevice(tunDev, conn.NewDefaultBind(), logger)

	// 5. IPC 配置
	if err := m.dev.IpcSet(buildUAPI(profile)); err != nil {
		m.cleanup()
		return fmt.Errorf("IPC 配置: %w", err)
	}

	// 6. 启动 UDP — 此时 endpoint 排除路由已就位，UDP 包走物理接口
	if err := m.dev.BindUpdate(); err != nil {
		m.cleanup()
		return fmt.Errorf("BindUpdate: %w", err)
	}
	log.Printf("[tunnel] BindUpdate 完成，UDP 包走 %s", m.physIface)

	// 7. 配置 TUN IP
	if profile.Interface.Address != "" {
		if err := configureInterface(m.tunName, profile.Interface.Address); err != nil {
			m.cleanup()
			return fmt.Errorf("配置 TUN IP: %w", err)
		}
		log.Printf("[tunnel] TUN IP: %s", profile.Interface.Address)
	}

	// 8. 添加探测路由（仅 1.1.1.1/32 → TUN）
	//    不加全量路由，避免握手失败时全流量黑洞。
	//    1.1.1.1 的流量进入 TUN → wireguard-go 尝试加密 → 触发握手发起。
	probeTarget := "1.1.1.1/32"
	if err := m.addTunnelRoute(probeTarget); err != nil {
		m.cleanup()
		return fmt.Errorf("添加探测路由: %w", err)
	}
	log.Printf("[tunnel] 探测路由已添加 (1.1.1.1/32 → %s)", m.tunName)

	// 9. 等待握手（探测流量触发握手，不影响其他网络流量）
	log.Printf("[tunnel] 等待握手（最多 15s）...")
	handshakeOK := m.waitForHandshake(15 * time.Second)
	if !handshakeOK {
		log.Printf("[tunnel] ⚠️ 握手失败，清理探测路由")
		m.cleanup()
		return fmt.Errorf("WG 握手失败（15s 内无响应）— 仅 1.1.1.1 受影响，其他网络正常")
	}
	log.Printf("[tunnel] ✅ 握手成功，添加全量路由")

	// 10. 握手成功，删除探测路由，添加全量隧道路由
	m.removeRoute(routeEntry{cidr: "1.1.1.1/32", dev: m.tunName})
	for _, peer := range profile.Peers {
		for _, cidr := range peer.AllowedIPs {
			if err := m.addTunnelRoute(cidr); err != nil {
				m.cleanup()
				return fmt.Errorf("添加隧道路由 %s: %w", cidr, err)
			}
		}
	}
	log.Printf("[tunnel] 全量隧道路由已添加 (0/1 + 128.0/1 → %s)", m.tunName)

	// 不修改系统 DNS
	return nil
}

// waitForHandshake 等待 wireguard-go 设备完成握手。
// 通过轮询 IPC 获取 peer 的 latest handshake 时间来判断。
func (m *darwinManager) waitForHandshake(timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		// 从 IPC 获取 peer 状态
		ipc, err := m.dev.IpcGet()
		if err != nil {
			time.Sleep(500 * time.Millisecond)
			continue
		}
		// 查找 latest_handshake 不为 0
		for _, line := range strings.Split(ipc, "\n") {
			if strings.HasPrefix(line, "latest_handshake=") {
				ts := strings.TrimPrefix(line, "latest_handshake=")
				if ts != "0" && ts != "" {
					return true
				}
			}
		}
		time.Sleep(500 * time.Millisecond)
	}
	return false
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
	m.cleanup()
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

// ConfigDir 返回配置文件目录路径。
func (m *darwinManager) ConfigDir() string {
	return m.configDir
}

// SaveProfile 将 .conf 文本保存为 {name}.conf。
func (m *darwinManager) SaveProfile(name, content string) error {
	if err := os.MkdirAll(m.configDir, 0755); err != nil {
		return err
	}
	path := filepath.Join(m.configDir, name+".conf")
	return os.WriteFile(path, []byte(content), 0600)
}

// LoadProfileContent 读取 {name}.conf 的文本内容。
func (m *darwinManager) LoadProfileContent(name string) (string, error) {
	path := filepath.Join(m.configDir, name+".conf")
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return string(data), nil
}

// DeleteProfile 删除 {name}.conf。
func (m *darwinManager) DeleteProfile(name string) error {
	path := filepath.Join(m.configDir, name+".conf")
	return os.Remove(path)
}

// setupSignalHandler 注册信号处理，确保 daemon 被 kill 时清理路由。
func (m *darwinManager) setupSignalHandler() {
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP)
	go func() {
		sig := <-sigCh
		log.Printf("[tunnel] 收到信号 %v，清理路由...", sig)
		m.cleanup()
		os.Exit(1)
	}()
}

// cleanup 清理所有资源：删除路由、关闭设备。
// 不再恢复 DNS（因为没有修改过）。
func (m *darwinManager) cleanup() {
	if m.cleaned {
		return
	}
	m.cleaned = true

	log.Printf("[tunnel] cleanup: 删除 %d 条路由", len(m.addedRoutes))

	// 删除所有已添加的路由（逆序）
	for i := len(m.addedRoutes) - 1; i >= 0; i-- {
		r := m.addedRoutes[i]
		deleteRoute(r)
	}
	m.addedRoutes = nil

	// 关闭 WG 设备（销毁 utun）
	if m.dev != nil {
		m.dev.Close()
		m.dev = nil
	}
}

// addExclusionRoute 添加排除路由（不走隧道）。
// gw 非空时走网关，gw 空时走物理接口。
func (m *darwinManager) addExclusionRoute(cidr, gw string) error {
	var cmd *exec.Cmd
	if gw != "" {
		cmd = exec.Command("route", "-n", "add", "-host", cidr, gw)
	} else {
		cmd = exec.Command("route", "-n", "add", "-net", cidr, "-interface", m.physIface)
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		// "File exists" 不是错误（路由已存在）
		if strings.Contains(string(out), "File exists") {
			log.Printf("[tunnel] 路由已存在（跳过）: %s", cidr)
		} else {
			return fmt.Errorf("%s: %s", strings.TrimSpace(string(out)), err)
		}
	}
	m.addedRoutes = append(m.addedRoutes, routeEntry{cidr: cidr, gw: gw, dev: m.physIface})
	log.Printf("[tunnel] 排除路由: %s via %s", cidr, gw)
	return nil
}

// addTunnelRoute 添加隧道路由。0.0.0.0/0 拆分为 0/1 + 128.0/1。
func (m *darwinManager) addTunnelRoute(cidr string) error {
	if cidr == "0.0.0.0/0" {
		if err := m.addTunnelRoute("0/1"); err != nil {
			return err
		}
		return m.addTunnelRoute("128.0/1")
	}
	if cidr == "::/0" {
		if err := m.addTunnelRoute("::/1"); err != nil {
			return err
		}
		return m.addTunnelRoute("8000::/1")
	}
	var cmd *exec.Cmd
	if strings.Contains(cidr, ":") {
		cmd = exec.Command("route", "-n", "add", "-inet6", cidr, "-interface", m.tunName)
	} else {
		cmd = exec.Command("route", "-n", "add", "-net", cidr, "-interface", m.tunName)
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		if strings.Contains(string(out), "File exists") {
			log.Printf("[tunnel] 隧道路由已存在（跳过）: %s", cidr)
		} else {
			return fmt.Errorf("%s: %s", strings.TrimSpace(string(out)), err)
		}
	}
	m.addedRoutes = append(m.addedRoutes, routeEntry{cidr: cidr, gw: "", dev: m.tunName})
	return nil
}

// removeRoute 删除单条路由（不经过 addedRoutes 列表）。
func (m *darwinManager) removeRoute(r routeEntry) {
	var cmd *exec.Cmd
	if r.gw != "" {
		cmd = exec.Command("route", "-n", "delete", "-host", r.cidr, r.gw)
	} else if r.dev != "" {
		if strings.Contains(r.cidr, ":") {
			cmd = exec.Command("route", "-n", "delete", "-inet6", r.cidr, "-interface", r.dev)
		} else {
			cmd = exec.Command("route", "-n", "delete", "-net", r.cidr, "-interface", r.dev)
		}
	}
	if cmd != nil {
		_ = cmd.Run()
	}
}

// --- 网络工具函数 ---

// getDefaultGateway 获取物理接口的默认网关 IP（跳过 utun/bridge 等虚拟接口）。
func getDefaultGateway() (string, error) {
	return getPhysicalGatewayFromNetstat()
}

// getDefaultInterface 获取物理默认接口名（en0/en1 等），跳过 utun/bridge/pdp/ipsec。
func getDefaultInterface() (string, error) {
	out, err := exec.Command("netstat", "-rn", "-f", "inet").CombinedOutput()
	if err != nil {
		return "", err
	}
	for _, line := range strings.Split(string(out), "\n") {
		if !strings.HasPrefix(strings.TrimSpace(line), "default") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 4 {
			continue
		}
		iface := fields[len(fields)-1]
		if strings.HasPrefix(iface, "en") {
			return iface, nil
		}
	}
	return "", fmt.Errorf("未找到物理默认接口")
}

// getPhysicalGatewayFromNetstat 从 netstat 输出中提取物理接口的网关。
func getPhysicalGatewayFromNetstat() (string, error) {
	out, err := exec.Command("netstat", "-rn", "-f", "inet").CombinedOutput()
	if err != nil {
		return "", err
	}
	for _, line := range strings.Split(string(out), "\n") {
		if !strings.HasPrefix(strings.TrimSpace(line), "default") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 4 {
			continue
		}
		iface := fields[len(fields)-1]
		if strings.HasPrefix(iface, "en") {
			return fields[1], nil
		}
	}
	return "", fmt.Errorf("未找到物理网关")
}

// getLocalNetwork 获取默认接口的本地网段 CIDR（如 10.10.1.0/24 或 192.168.200.0/22）。
func getLocalNetwork() (string, error) {
	iface, err := getDefaultInterface()
	if err != nil {
		return "", err
	}
	netIface, err := net.InterfaceByName(iface)
	if err != nil {
		return "", err
	}
	addrs, err := netIface.Addrs()
	if err != nil {
		return "", err
	}
	for _, addr := range addrs {
		if ipnet, ok := addr.(*net.IPNet); ok {
			if ip4 := ipnet.IP.To4(); ip4 != nil {
				return ipnet.String(), nil
			}
		}
	}
	return "", fmt.Errorf("未找到 IPv4 地址")
}

// resolveEndpoint 将 host:port 的 host 解析为 IP。
func resolveEndpoint(endpoint string) (string, error) {
	host, _, err := net.SplitHostPort(endpoint)
	if err != nil {
		host = endpoint
	}
	ips, err := net.LookupHost(host)
	if err != nil || len(ips) == 0 {
		return "", fmt.Errorf("解析 %s: %w", host, err)
	}
	return ips[0], nil
}

// deleteRoute 删除一条路由。
func deleteRoute(r routeEntry) {
	var cmd *exec.Cmd
	if r.gw != "" {
		// 排除路由（via 网关）
		cmd = exec.Command("route", "-n", "delete", "-host", r.cidr, r.gw)
	} else if r.dev != "" {
		// 接口路由
		if strings.Contains(r.cidr, ":") {
			cmd = exec.Command("route", "-n", "delete", "-inet6", r.cidr, "-interface", r.dev)
		} else {
			cmd = exec.Command("route", "-n", "delete", "-net", r.cidr, "-interface", r.dev)
		}
	}
	if cmd != nil {
		_ = cmd.Run()
	}
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

func parseCIDR(cidr string) (ip, mask string, err error) {
	parts := strings.SplitN(cidr, "/", 2)
	if len(parts) != 2 {
		return "", "", fmt.Errorf("无效 CIDR: %s", cidr)
	}
	return parts[0], parts[1], nil
}
