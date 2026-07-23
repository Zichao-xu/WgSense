// Package tunnel 的 macOS 实现:基于 wireguard-go + utun。
// 注意:CreateTUN 和配置 IP/路由需要 root，开发阶段用 sudo 跑 daemon。
// 阶段 1 后期迁移到 NetworkExtension 后不再需要 root。
//
// 重要设计决策：
//  1. 只在隧道握手成功后临时应用 profile DNS，cleanup 恢复原 DNS，避免 Fake-IP DNS
//     在全隧道路由下把域名解析到不可达地址。
//  2. endpoint 排除路由在 BindUpdate 之前添加 — 确保 WG UDP 握手包走物理接口。
//  3. cleanup 注册 signal handler — 尽量在进程退出时恢复 DNS 并清理路由。
package tunnel

import (
	"context"
	"encoding/json"
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
	origGateway string       // 建隧道前的物理网关
	physIface   string       // 物理接口名（en0/en1）
	addedRoutes []routeEntry // 已添加的路由（断开时清理）
	dnsSnapshot *dnsSnapshot // 已替换 DNS 时的原始设置
	cleaned     bool         // 防止重复 cleanup
	hasIPv6     bool         // TUN 是否配置了 IPv6 地址
}

type routeEntry struct {
	cidr string
	gw   string // 网关 IP（空=interface 路由）
	dev  string // 接口名
}

type dnsSnapshot struct {
	Service string   `json:"service"`
	Servers []string `json:"servers"`
}

func newPlatformManager(configDir string) Manager {
	return &darwinManager{configDir: configDir}
}

// ConnectWithProfile 用配置 profile 启动 WG 隧道(wireguard-go + utun)。
// 需要 root(CreateTUN + ifconfig + route)。
func (m *darwinManager) ConnectWithProfile(profile *config.Profile) error {
	// 重置 cleanup 标志，允许新一轮清理
	m.cleaned = false
	m.hasIPv6 = false
	if err := restoreStaleDNS(m.configDir); err != nil {
		log.Printf("[tunnel] 启动前恢复残留 DNS 失败: %v", err)
	}

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
	for i, peer := range profile.Peers {
		if peer.Endpoint != "" {
			ip, err := resolveEndpoint(peer.Endpoint)
			if err != nil {
				return fmt.Errorf("解析 endpoint %s: %w", peer.Endpoint, err)
			}
			endpointIP = ip
			log.Printf("[tunnel] endpoint %s → %s", peer.Endpoint, ip)

			// 把 endpoint 从 host:port 替换为 ip:port，避免 wireguard-go 内部再解析域名
			host, port, _ := net.SplitHostPort(peer.Endpoint)
			if host != ip {
				profile.Peers[i].Endpoint = ip + ":" + port
				log.Printf("[tunnel] UAPI endpoint 改为 IP: %s", profile.Peers[i].Endpoint)
			}

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

	// 5. IPC 配置（IpcSet 内部会触发 BindUpdate + 握手发起，不需要再显式调用 BindUpdate）
	uapi := buildUAPI(profile)
	log.Printf("[tunnel] 应用 WireGuard 配置：%d 个 peer", len(profile.Peers))
	if err := m.dev.IpcSet(uapi); err != nil {
		m.cleanup()
		return fmt.Errorf("IPC 配置: %w", err)
	}
	log.Printf("[tunnel] IpcSet 完成（含内部 BindUpdate + 握手发起）")

	// 7. 配置 TUN IP。WireGuard Address 可包含多个 CIDR，例如 IPv4 + IPv6。
	if profile.Interface.Address != "" {
		hasIPv6, err := configureInterfaceAddresses(m.tunName, profile.Interface.Address)
		if err != nil {
			m.cleanup()
			return fmt.Errorf("配置 TUN IP: %w", err)
		}
		m.hasIPv6 = hasIPv6
		log.Printf("[tunnel] TUN IP: %s", profile.Interface.Address)
	}

	// 8. 等待握手（IpcSet 已自动发起握手，不需要外部流量触发）
	//    不加任何路由 → 握手失败时不影响网络
	log.Printf("[tunnel] 等待握手（最多 15s）...")
	handshakeOK := m.waitForHandshake(15 * time.Second)
	if !handshakeOK {
		m.cleanup()
		return fmt.Errorf("WG 握手失败（15s 内无响应）")
	}
	log.Printf("[tunnel] ✅ 握手成功，添加全量路由")

	// 9. 握手成功，添加全量隧道路由（0.0.0.0/0 拆分为 0/1 + 128.0/1）
	for _, peer := range profile.Peers {
		for _, cidr := range plannedTunnelRoutes(peer.AllowedIPs, m.hasIPv6) {
			if err := m.addTunnelRoute(cidr); err != nil {
				m.cleanup()
				return fmt.Errorf("添加隧道路由 %s: %w", cidr, err)
			}
		}
	}
	log.Printf("[tunnel] 全量隧道路由已添加 (0/1 + 128.0/1 → %s)", m.tunName)

	if err := m.applyProfileDNS(profile.Interface.DNS); err != nil {
		m.cleanup()
		return fmt.Errorf("应用 DNS: %w", err)
	}
	return nil
}

// waitForHandshake 等待 wireguard-go 设备完成握手。
// waitForHandshake 轮询 IPC 判断握手是否完成。
// IpcSet 创建 peer 时会自动发送 handshake initiation，不需要外部触发。
// 不依赖 ping（避免与 Clash fake-ip 等代理工具冲突）。
func (m *darwinManager) waitForHandshake(timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)

	for time.Now().Before(deadline) {
		ipc, err := m.dev.IpcGet()
		if err != nil {
			time.Sleep(500 * time.Millisecond)
			continue
		}
		// 查找 last_handshake_time_sec 不为 0
		for _, line := range strings.Split(ipc, "\n") {
			if strings.HasPrefix(line, "last_handshake_time_sec=") {
				ts := strings.TrimPrefix(line, "last_handshake_time_sec=")
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

// InterfaceBytes 返回当前活跃网络接口的累计发送/接收字节数。
// 从所有非 loopback 接口中选取流量最大的一个，避免叠加导致数值虚高。
func (m *darwinManager) InterfaceBytes(_ string) (tx, rx uint64) {
	return getActiveInterfaceBytes()
}

// getActiveInterfaceBytes 通过 netstat -ib 读取所有非 lo 接口，
// 取 ibytes+obytes 最大的那个接口作为当前活跃网络接口。
func getActiveInterfaceBytes() (tx, rx uint64) {
	out, err := exec.Command("netstat", "-ib").Output()
	if err != nil {
		return 0, 0
	}
	var bestTx, bestRx, bestTotal uint64
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 10 {
			continue
		}
		name := fields[0]
		// 排除 loopback
		if name == "lo0" {
			continue
		}
		// 只看 Link 层行
		if !strings.HasPrefix(fields[2], "<Link") {
			continue
		}
		// 跳过没有流量的接口
		var ibytes, obytes uint64
		if v, err := parseUint(fields[6]); err == nil {
			ibytes = v
		}
		if v, err := parseUint(fields[9]); err == nil {
			obytes = v
		}
		total := ibytes + obytes
		if total > bestTotal {
			bestTotal = total
			bestTx = obytes
			bestRx = ibytes
		}
	}
	return bestTx, bestRx
}

func parseUint(s string) (uint64, error) {
	var v uint64
	_, err := fmt.Sscanln(s, &v)
	return v, err
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

// cleanup 清理所有资源：先恢复临时 DNS，再删除路由、关闭设备。
func (m *darwinManager) cleanup() {
	if m.cleaned {
		return
	}
	m.cleaned = true

	log.Printf("[tunnel] cleanup: 删除 %d 条路由", len(m.addedRoutes))

	if m.dnsSnapshot != nil {
		if err := restoreDNS(*m.dnsSnapshot); err != nil {
			log.Printf("[tunnel] 恢复 DNS 失败: %v", err)
		} else {
			_ = removeStoredDNSSnapshot(m.configDir)
			log.Printf("[tunnel] DNS 已恢复: %s", m.dnsSnapshot.Service)
		}
		m.dnsSnapshot = nil
	}

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

func (m *darwinManager) applyProfileDNS(rawDNS string) error {
	servers := parseDNSServers(rawDNS)
	if len(servers) == 0 {
		return nil
	}
	service, err := networkServiceForInterface(m.physIface)
	if err != nil {
		return err
	}
	current, err := currentDNSServers(service)
	if err != nil {
		return err
	}
	if stringSlicesEqual(current, servers) {
		log.Printf("[tunnel] DNS 已是 profile 配置: %s", strings.Join(servers, ", "))
		return nil
	}
	m.dnsSnapshot = &dnsSnapshot{Service: service, Servers: current}
	if err := storeDNSSnapshot(m.configDir, *m.dnsSnapshot); err != nil {
		m.dnsSnapshot = nil
		return err
	}
	args := append([]string{"-setdnsservers", service}, servers...)
	if out, err := exec.Command("networksetup", args...).CombinedOutput(); err != nil {
		m.dnsSnapshot = nil
		_ = removeStoredDNSSnapshot(m.configDir)
		return fmt.Errorf("%s: %w", strings.TrimSpace(string(out)), err)
	}
	log.Printf("[tunnel] DNS 已切换到 profile: %s → %s", service, strings.Join(servers, ", "))
	return nil
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
			return nil
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
			return nil
		} else {
			return fmt.Errorf("%s: %s", strings.TrimSpace(string(out)), err)
		}
	}
	m.addedRoutes = append(m.addedRoutes, routeEntry{cidr: cidr, gw: "", dev: m.tunName})
	return nil
}

// plannedTunnelRoutes expands default routes and drops an address family that
// is not configured on the tunnel. Fake-IP ranges are deliberately untouched:
// a local proxy owns those routes and sending them to a physical NIC breaks DNS.
func plannedTunnelRoutes(allowedIPs []string, hasIPv6 bool) []string {
	routes := make([]string, 0, len(allowedIPs)+2)
	for _, cidr := range allowedIPs {
		cidr = strings.TrimSpace(cidr)
		switch {
		case cidr == "":
			continue
		case cidr == "0.0.0.0/0":
			routes = append(routes, "0/1", "128.0/1")
		case cidr == "::/0" && hasIPv6:
			routes = append(routes, "::/1", "8000::/1")
		case strings.Contains(cidr, ":") && !hasIPv6:
			continue
		default:
			routes = append(routes, cidr)
		}
	}
	return routes
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
	// 第一优先：default 路由的接口
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
	// 回退：找路由表中第一个 en* 接口
	enIfaces := map[string]bool{}
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 4 {
			continue
		}
		iface := fields[len(fields)-1]
		if strings.HasPrefix(iface, "en") && iface != "" {
			enIfaces[iface] = true
		}
	}
	for iface := range enIfaces {
		return iface, nil
	}
	return "", fmt.Errorf("未找到物理默认接口")
}

// getPhysicalGatewayFromNetstat 从 netstat 输出中提取物理接口的网关。
// 优先匹配 default 路由；如果 default 被遮蔽（如已加 0/1 隧道路由），
// 回退到扫描 en 接口的路由条目提取网关。
func getPhysicalGatewayFromNetstat() (string, error) {
	out, err := exec.Command("netstat", "-rn", "-f", "inet").CombinedOutput()
	if err != nil {
		return "", err
	}
	// 第一优先：default 路由走 en* 接口
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
	// 回退：找任何 en* 接口的 UG/UGSc 路由（通常是局域网网关）
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 4 {
			continue
		}
		iface := fields[len(fields)-1]
		if !strings.HasPrefix(iface, "en") {
			continue
		}
		// 匹配含 G(gateway) 标志的路由
		if strings.Contains(fields[2], "G") && strings.Contains(fields[1], ".") {
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
	if err == nil {
		if ip := firstNonFakeIP(ips); ip != "" {
			return ip, nil
		}
	}

	bootstrapIPs, bootstrapErr := lookupEndpointWithBootstrapDNS(host)
	if bootstrapErr == nil {
		if ip := firstNonFakeIP(bootstrapIPs); ip != "" {
			return ip, nil
		}
	}

	if len(ips) > 0 {
		return "", fmt.Errorf("解析 %s 得到代理 Fake-IP %v；bootstrap DNS 也未返回可用公网 IP: %v", host, ips, bootstrapErr)
	}
	return "", fmt.Errorf("解析 %s: %w", host, err)
}

func firstNonFakeIP(ips []string) string {
	for _, candidate := range ips {
		ip := net.ParseIP(candidate)
		if ip == nil {
			continue
		}
		if isFakeIP(ip) {
			continue
		}
		return candidate
	}
	return ""
}

func lookupEndpointWithBootstrapDNS(host string) ([]string, error) {
	servers := []string{"223.5.5.5:53", "119.29.29.29:53", "1.1.1.1:53", "8.8.8.8:53"}
	var lastErr error
	for _, server := range servers {
		resolver := &net.Resolver{
			PreferGo: true,
			Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
				d := net.Dialer{Timeout: 3 * time.Second}
				return d.DialContext(ctx, "udp", server)
			},
		}
		ctx, cancel := context.WithTimeout(context.Background(), 4*time.Second)
		ips, err := resolver.LookupHost(ctx, host)
		cancel()
		if err == nil && len(ips) > 0 {
			return ips, nil
		}
		lastErr = err
	}
	return nil, lastErr
}

func isFakeIP(ip net.IP) bool {
	ip4 := ip.To4()
	if ip4 == nil {
		return false
	}
	_, fakeNet, _ := net.ParseCIDR("198.18.0.0/15")
	return fakeNet.Contains(ip4)
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

// configureInterfaceAddresses 用 ifconfig 设置 TUN 的 IP 地址(需 root)。
func configureInterfaceAddresses(name, addresses string) (bool, error) {
	hasIPv6 := false
	for _, address := range strings.Split(addresses, ",") {
		address = strings.TrimSpace(address)
		if address == "" {
			continue
		}
		if strings.Contains(address, ":") {
			hasIPv6 = true
		}
		if err := configureInterface(name, address); err != nil {
			return hasIPv6, err
		}
	}
	return hasIPv6, nil
}

func configureInterface(name, address string) error {
	ip, mask, err := parseCIDR(address)
	if err != nil {
		return err
	}
	var cmd *exec.Cmd
	if strings.Contains(ip, ":") {
		cmd = exec.Command("ifconfig", name, "inet6", ip, "prefixlen", mask)
	} else {
		cmd = exec.Command("ifconfig", name, "inet", ip, ip, "prefixlen", mask)
	}
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

func parseDNSServers(raw string) []string {
	var servers []string
	for _, part := range strings.FieldsFunc(raw, func(r rune) bool {
		return r == ',' || r == ' ' || r == '\t' || r == '\n'
	}) {
		server := strings.TrimSpace(part)
		if server == "" {
			continue
		}
		servers = append(servers, server)
	}
	return servers
}

func networkServiceForInterface(iface string) (string, error) {
	out, err := exec.Command("networksetup", "-listallhardwareports").CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("%s: %w", strings.TrimSpace(string(out)), err)
	}
	return parseNetworkServiceForInterface(string(out), iface)
}

func parseNetworkServiceForInterface(output, iface string) (string, error) {
	var currentPort string
	for _, rawLine := range strings.Split(output, "\n") {
		line := strings.TrimSpace(rawLine)
		switch {
		case strings.HasPrefix(line, "Hardware Port:"):
			currentPort = strings.TrimSpace(strings.TrimPrefix(line, "Hardware Port:"))
		case strings.HasPrefix(line, "Device:"):
			device := strings.TrimSpace(strings.TrimPrefix(line, "Device:"))
			if device == iface && currentPort != "" {
				return currentPort, nil
			}
		}
	}
	return "", fmt.Errorf("未找到接口 %s 对应的网络服务", iface)
}

func currentDNSServers(service string) ([]string, error) {
	out, err := exec.Command("networksetup", "-getdnsservers", service).CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("%s: %w", strings.TrimSpace(string(out)), err)
	}
	return parseCurrentDNSServers(string(out)), nil
}

func parseCurrentDNSServers(output string) []string {
	var servers []string
	for _, rawLine := range strings.Split(output, "\n") {
		line := strings.TrimSpace(rawLine)
		if line == "" {
			continue
		}
		if strings.Contains(line, "There aren't any DNS Servers") || strings.Contains(line, "没有设置 DNS") {
			return nil
		}
		servers = append(servers, line)
	}
	return servers
}

func restoreDNS(snapshot dnsSnapshot) error {
	args := []string{"-setdnsservers", snapshot.Service}
	if len(snapshot.Servers) == 0 {
		args = append(args, "Empty")
	} else {
		args = append(args, snapshot.Servers...)
	}
	if out, err := exec.Command("networksetup", args...).CombinedOutput(); err != nil {
		return fmt.Errorf("%s: %w", strings.TrimSpace(string(out)), err)
	}
	return nil
}

func storeDNSSnapshot(configDir string, snapshot dnsSnapshot) error {
	if err := os.MkdirAll(configDir, 0755); err != nil {
		return err
	}
	data, err := json.Marshal(snapshot)
	if err != nil {
		return err
	}
	return os.WriteFile(dnsSnapshotPath(configDir), data, 0600)
}

func restoreStaleDNS(configDir string) error {
	data, err := os.ReadFile(dnsSnapshotPath(configDir))
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	var snapshot dnsSnapshot
	if err := json.Unmarshal(data, &snapshot); err != nil {
		return err
	}
	if snapshot.Service == "" {
		_ = removeStoredDNSSnapshot(configDir)
		return nil
	}
	if err := restoreDNS(snapshot); err != nil {
		return err
	}
	return removeStoredDNSSnapshot(configDir)
}

func removeStoredDNSSnapshot(configDir string) error {
	err := os.Remove(dnsSnapshotPath(configDir))
	if os.IsNotExist(err) {
		return nil
	}
	return err
}

func dnsSnapshotPath(configDir string) string {
	return filepath.Join(configDir, ".wgsense-dns-snapshot.json")
}

func stringSlicesEqual(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
