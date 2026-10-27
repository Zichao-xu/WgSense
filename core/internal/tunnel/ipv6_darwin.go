package tunnel

// 全局隧道的 IPv6：有就用，没有就不用，但永远不绕开隧道。
//
// WireGuard 不会下发地址，所以隧道的 IPv6 地址按约定从 IPv4 推出：
// 10.66.66.3 → fd77:6773::10.66.66.3/96。服务器哪天要开 IPv6，只需在
// 自己的 WG 接口上配同一约定的地址(如 fd77:6773::10.66.66.1/96)、
// 给 peer 放行对应 /128 并做 IPv6 出口转发，本机不用改任何配置。
//
// 连上后公网 IPv6 先指向拒绝路由(连接立即失败，程序马上退回 IPv4 进隧道)，
// 再经隧道探测 IPv6 能否出网：通了就把公网 IPv6 切进隧道，不通就保持拒绝，
// 之后定期复查，两个方向都会自动切换。

import (
	"fmt"
	"log"
	"net"
	"net/netip"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// autoIPv6Prefix 是隧道 IPv6 地址约定：前缀 + 本机隧道 IPv4。
const autoIPv6Prefix = "fd77:6773::"

// ipv6DefaultRoutes 覆盖全部公网 IPv6，比物理网卡的 ::/0 更具体；
// 链路本地与局域网前缀路由更具体，不受影响。
var ipv6DefaultRoutes = []string{"::/1", "8000::/1"}

// ipv6GuardRoutes 在切换 /1 路由的瞬间临时兜底，切换过程不会漏到物理网卡。
var ipv6GuardRoutes = []string{"::/2", "4000::/2", "8000::/2", "c000::/2"}

// ipv6ProbeTargets 经隧道探测 IPv6 出网，任一连通即算有。
var ipv6ProbeTargets = []string{
	"[2400:3200::1]:53",         // 阿里 DNS
	"[2402:4e00::]:53",          // 腾讯 DNSPod
	"[2001:4860:4860::8888]:53", // Google DNS
}

const (
	ipv6ProbeTimeout = 3 * time.Second
	ipv6FirstRetry   = 30 * time.Second
	ipv6Recheck      = 5 * time.Minute
)

// isFullTunnel 判断是否全局隧道。分流配置不碰 IPv6。
func isFullTunnel(allowedIPs []string) bool {
	for _, cidr := range allowedIPs {
		if c := strings.TrimSpace(cidr); c == "0.0.0.0/0" || c == "::/0" {
			return true
		}
	}
	return false
}

// autoIPv6Address 按约定从隧道 IPv4 推出 IPv6 地址；没有 IPv4 时返回空。
func autoIPv6Address(addresses string) string {
	for _, address := range strings.Split(addresses, ",") {
		prefix, err := netip.ParsePrefix(strings.TrimSpace(address))
		if err != nil || !prefix.Addr().Is4() {
			continue
		}
		return autoIPv6Prefix + prefix.Addr().String() + "/96"
	}
	return ""
}

// ensureAllowedIPv6 让 wireguard-go 接受经隧道的 IPv6 包。服务器没开 IPv6 时
// 这些包只有探测会发，对端丢弃即可。
func ensureAllowedIPv6(allowedIPs []string) []string {
	for _, cidr := range allowedIPs {
		if strings.TrimSpace(cidr) == "::/0" {
			return allowedIPs
		}
	}
	return append(allowedIPs, "::/0")
}

type ipv6Switch struct {
	tun     string
	mu      sync.Mutex
	tunnel  bool // true=公网 IPv6 走隧道；false=拒绝
	probe   func() bool
	install func(viaTunnel bool) error
	stop    chan struct{}
	done    chan struct{}
}

// startIPv6Switch 先装拒绝路由，再在后台探测并按结果切换。
func startIPv6Switch(tun string) (*ipv6Switch, error) {
	s := &ipv6Switch{
		tun:   tun,
		probe: func() bool { return probeIPv6Via(tun) },
		stop:  make(chan struct{}),
		done:  make(chan struct{}),
	}
	s.install = s.installRoutes
	if err := s.install(false); err != nil {
		return nil, err
	}
	log.Printf("[tunnel] 公网 IPv6 暂时拒绝，探测隧道 IPv6 出网中")
	go s.loop()
	return s, nil
}

func (s *ipv6Switch) loop() {
	defer close(s.done)
	// 连上立即探测；刚连上时服务器可能还没就绪，30 秒后再试一次，之后定期复查
	waits := []time.Duration{0, ipv6FirstRetry}
	for i := 0; ; i++ {
		wait := ipv6Recheck
		if i < len(waits) {
			wait = waits[i]
		}
		select {
		case <-s.stop:
			return
		case <-time.After(wait):
		}
		s.check()
	}
}

func (s *ipv6Switch) viaTunnel() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.tunnel
}

// check 探测一次，结果与当前状态不同才切换。
func (s *ipv6Switch) check() {
	ok := s.probe()
	s.mu.Lock()
	defer s.mu.Unlock()
	if ok == s.tunnel {
		return
	}
	select {
	case <-s.stop:
		return
	default:
	}
	if err := s.install(ok); err != nil {
		log.Printf("[tunnel] 切换公网 IPv6 失败: %v", err)
		return
	}
	s.tunnel = ok
	if ok {
		log.Printf("[tunnel] 隧道 IPv6 可出网，公网 IPv6 改走 %s", s.tun)
	} else {
		log.Printf("[tunnel] 隧道 IPv6 不可出网，公网 IPv6 改为拒绝（程序退回 IPv4 进隧道）")
	}
}

// close 停止探测并删除所有公网 IPv6 路由。
func (s *ipv6Switch) close() {
	close(s.stop)
	<-s.done
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, cidr := range ipv6DefaultRoutes {
		deleteIPv6Route(cidr, s.tunnel, s.tun)
	}
}

// installRoutes 把公网 IPv6 路由切到隧道或拒绝。先装更细的拒绝路由兜底，
// 换完再撤，切换瞬间 IPv6 也不会落到物理网卡的默认路由上。
func (s *ipv6Switch) installRoutes(viaTunnel bool) error {
	for _, cidr := range ipv6GuardRoutes {
		if err := addIPv6Route(cidr, false, ""); err != nil {
			return err
		}
	}
	defer func() {
		for _, cidr := range ipv6GuardRoutes {
			deleteIPv6Route(cidr, false, "")
		}
	}()
	for _, cidr := range ipv6DefaultRoutes {
		deleteIPv6Route(cidr, !viaTunnel, s.tun)
		deleteIPv6Route(cidr, viaTunnel, s.tun) // 残留同类路由
		if err := addIPv6Route(cidr, viaTunnel, s.tun); err != nil {
			return err
		}
	}
	return nil
}

func addIPv6Route(cidr string, viaTunnel bool, tun string) error {
	args := []string{"-n", "add", "-inet6", cidr, "::1", "-reject"}
	if viaTunnel {
		args = []string{"-n", "add", "-inet6", cidr, "-interface", tun}
	}
	out, err := exec.Command("route", args...).CombinedOutput()
	if err != nil && !strings.Contains(string(out), "File exists") {
		return fmt.Errorf("route %s: %s: %w", strings.Join(args, " "), strings.TrimSpace(string(out)), err)
	}
	return nil
}

func deleteIPv6Route(cidr string, viaTunnel bool, tun string) {
	args := []string{"-n", "delete", "-inet6", cidr, "::1"}
	if viaTunnel {
		args = []string{"-n", "delete", "-inet6", cidr, "-interface", tun}
	}
	_ = exec.Command("route", args...).Run()
}

// clearStaleIPv6Routes 清理上次 daemon 被强杀残留的拒绝/兜底路由。
// 残留的隧道路由随 utun 销毁自动消失，不用管。
func clearStaleIPv6Routes() {
	for _, cidr := range append(append([]string(nil), ipv6DefaultRoutes...), ipv6GuardRoutes...) {
		deleteIPv6Route(cidr, false, "")
	}
	for _, target := range ipv6ProbeTargets {
		if host, _, err := net.SplitHostPort(target); err == nil {
			_ = exec.Command("route", "-n", "delete", "-inet6", "-host", host).Run()
		}
	}
}

// probeIPv6Via 给探测目标临时加指向隧道的主机路由，并行连接，任一连通即算
// 隧道 IPv6 可出网。主机路由比公网 IPv6 路由更具体，无论当前是拒绝还是隧道
// 都只经隧道探测。最多耗时 ipv6ProbeTimeout。
func probeIPv6Via(tun string) bool {
	var hosts []string
	for _, target := range ipv6ProbeTargets {
		host, _, err := net.SplitHostPort(target)
		if err != nil {
			continue
		}
		if exec.Command("route", "-n", "add", "-inet6", "-host", host, "-interface", tun).Run() == nil {
			hosts = append(hosts, host)
		}
	}
	defer func() {
		for _, host := range hosts {
			_ = exec.Command("route", "-n", "delete", "-inet6", "-host", host, "-interface", tun).Run()
		}
	}()
	results := make(chan bool, len(ipv6ProbeTargets))
	for _, target := range ipv6ProbeTargets {
		go func(target string) {
			conn, err := net.DialTimeout("tcp6", target, ipv6ProbeTimeout)
			if err == nil {
				conn.Close()
			}
			results <- err == nil
		}(target)
	}
	ok := false
	for range ipv6ProbeTargets {
		if <-results {
			ok = true
		}
	}
	return ok
}
