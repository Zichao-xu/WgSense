package tunnel

// 全局隧道的公网 IPv6：有就用，没有就不用，但永远不绕开隧道。
//
// WireGuard 不会下发地址，所以隧道 IPv6 地址按约定从 IPv4 推出（见
// IPv6Settings.Prefix）。服务器哪天要开 IPv6，只需按同一约定配地址、放行
// peer 的 /128 并做 IPv6 出口转发，本机不用改任何配置。
//
// 连上后公网 IPv6 先指向拒绝路由（连接立即失败，程序马上退回 IPv4 进隧道），
// 再经隧道探测 IPv6 能否出网：通了就把公网 IPv6 切进隧道，不通就保持拒绝，
// 之后定期复查，两个方向都会自动切换。设置为「始终拒绝」时不探测。

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

// ipv6DefaultRoutes 覆盖全部公网 IPv6，比物理网卡的 ::/0 更具体；
// 链路本地与局域网前缀路由更具体，不受影响。
var ipv6DefaultRoutes = []string{"::/1", "8000::/1"}

// ipv6GuardRoutes 在切换 /1 路由的瞬间临时兜底，切换过程不会漏到物理网卡。
var ipv6GuardRoutes = []string{"::/2", "4000::/2", "8000::/2", "c000::/2"}

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

// autoIPv6Address 按约定从隧道 IPv4 推出 IPv6 地址（/96）；没有 IPv4 时返回空。
func autoIPv6Address(prefix, addresses string) string {
	for _, address := range strings.Split(addresses, ",") {
		p, err := netip.ParsePrefix(strings.TrimSpace(address))
		if err != nil || !p.Addr().Is4() {
			continue
		}
		addr, err := deriveIPv6(prefix, p.Addr())
		if err != nil {
			return ""
		}
		return addr.String() + "/96"
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
	targets func() []string
	probe   func(targets []string) bool
	install func(viaTunnel bool) error

	mu        sync.Mutex
	tunnel    bool // true=公网 IPv6 走隧道；false=拒绝
	block     bool // 始终拒绝，不探测
	probed    bool
	lastProbe time.Time
	lastOK    bool
	nextProbe time.Time
	lastErr   string
	stop      chan struct{} // 当前探测循环；nil 表示未运行
	done      chan struct{}
}

// newIPv6Switch 创建切换器，尚未改动路由。
func newIPv6Switch(tun string, targets func() []string) *ipv6Switch {
	s := &ipv6Switch{tun: tun, targets: targets}
	s.probe = func(targets []string) bool { return probeIPv6Via(tun, targets) }
	s.install = s.installRoutes
	return s
}

// start 先装拒绝路由；自动模式下再在后台探测并按结果切换。
func (s *ipv6Switch) start(block bool) error {
	if err := s.install(false); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.block = block
	if block {
		log.Printf("[tunnel] 公网 IPv6 设为始终拒绝（程序改用 IPv4 进隧道）")
		return nil
	}
	log.Printf("[tunnel] 公网 IPv6 暂时拒绝，探测隧道 IPv6 出网中")
	s.startLoopLocked()
	return nil
}

func (s *ipv6Switch) startLoopLocked() {
	s.stop, s.done = make(chan struct{}), make(chan struct{})
	go s.loop(s.stop, s.done)
}

// stopLoop 停止探测循环并等它退出（会等完正在进行的探测）。
func (s *ipv6Switch) stopLoop() {
	s.mu.Lock()
	stop, done := s.stop, s.done
	s.stop, s.done = nil, nil
	s.mu.Unlock()
	if stop != nil {
		close(stop)
		<-done
	}
}

func (s *ipv6Switch) loop(stop, done chan struct{}) {
	defer close(done)
	// 连上立即探测；刚连上时服务器可能还没就绪，30 秒后再试一次，之后定期复查
	waits := []time.Duration{0, ipv6FirstRetry}
	for i := 0; ; i++ {
		wait := ipv6Recheck
		if i < len(waits) {
			wait = waits[i]
		}
		s.mu.Lock()
		s.nextProbe = time.Now().Add(wait)
		s.mu.Unlock()
		select {
		case <-stop:
			return
		case <-time.After(wait):
		}
		s.check(stop)
	}
}

// check 探测一次，结果与当前状态不同才切换。
func (s *ipv6Switch) check(stop chan struct{}) {
	ok := s.probe(s.targets())
	s.mu.Lock()
	defer s.mu.Unlock()
	s.probed, s.lastProbe, s.lastOK = true, time.Now(), ok
	select {
	case <-stop:
		return
	default:
	}
	if ok == s.tunnel {
		return
	}
	if err := s.install(ok); err != nil {
		s.lastErr = err.Error()
		log.Printf("[tunnel] 切换公网 IPv6 失败: %v", err)
		return
	}
	s.tunnel, s.lastErr = ok, ""
	if ok {
		log.Printf("[tunnel] 隧道 IPv6 可出网，公网 IPv6 改走 %s", s.tun)
	} else {
		log.Printf("[tunnel] 隧道 IPv6 不可出网，公网 IPv6 改为拒绝（程序退回 IPv4 进隧道）")
	}
}

// setBlock 即时切换「始终拒绝」与「自动」。
func (s *ipv6Switch) setBlock(block bool) {
	s.mu.Lock()
	same := s.block == block
	s.mu.Unlock()
	if same {
		return
	}
	if block {
		s.stopLoop()
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.block = block
	if block {
		if s.tunnel {
			if err := s.install(false); err != nil {
				s.lastErr = err.Error()
				return
			}
			s.tunnel = false
		}
		s.probed, s.nextProbe = false, time.Time{}
		log.Printf("[tunnel] 公网 IPv6 改为始终拒绝")
		return
	}
	log.Printf("[tunnel] 公网 IPv6 改为自动，开始探测")
	s.startLoopLocked()
}

// recheck 立即重新探测（如修改了探测地址）。
func (s *ipv6Switch) recheck() {
	s.mu.Lock()
	running := s.stop != nil
	s.mu.Unlock()
	if running {
		s.stopLoop()
		s.mu.Lock()
		s.startLoopLocked()
		s.mu.Unlock()
	}
}

func (s *ipv6Switch) status() IPv6Status {
	s.mu.Lock()
	defer s.mu.Unlock()
	st := IPv6Status{Mode: IPv6ModeAuto, Targets: s.targets(), Error: s.lastErr}
	switch {
	case s.block:
		st.Mode, st.State, st.Targets = IPv6ModeBlock, IPv6StateBlocked, nil
	case s.tunnel:
		st.State = IPv6StateTunnel
	case !s.probed:
		st.State = IPv6StateProbing
	default:
		st.State = IPv6StateBlocked
	}
	if s.probed {
		st.LastProbe, st.LastProbeOK = s.lastProbe.Format(time.RFC3339), s.lastOK
	}
	if !s.block && !s.nextProbe.IsZero() {
		st.NextProbe = s.nextProbe.Format(time.RFC3339)
	}
	return st
}

// close 停止探测并删除所有公网 IPv6 路由。
func (s *ipv6Switch) close() {
	s.stopLoop()
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

// clearStaleIPv6Routes 清理上次 daemon 被强杀残留的拒绝/兜底路由与探测主机路由。
// 残留的隧道路由随 utun 销毁自动消失，不用管。
func clearStaleIPv6Routes(targets []string) {
	for _, cidr := range append(append([]string(nil), ipv6DefaultRoutes...), ipv6GuardRoutes...) {
		deleteIPv6Route(cidr, false, "")
	}
	for _, target := range targets {
		if host, _, err := net.SplitHostPort(target); err == nil {
			_ = exec.Command("route", "-n", "delete", "-inet6", "-host", host).Run()
		}
	}
}

// probeIPv6Via 给探测目标临时加指向隧道的主机路由，并行连接，任一连通即算
// 隧道 IPv6 可出网。主机路由比公网 IPv6 路由更具体，无论当前是拒绝还是隧道
// 都只经隧道探测；加不上主机路由的目标不探测，避免误走其他出口。
// 最多耗时 ipv6ProbeTimeout。
func probeIPv6Via(tun string, targets []string) bool {
	var routed []string
	for _, target := range targets {
		host, _, err := net.SplitHostPort(target)
		if err != nil {
			continue
		}
		if exec.Command("route", "-n", "add", "-inet6", "-host", host, "-interface", tun).Run() == nil {
			routed = append(routed, target)
		}
	}
	defer func() {
		for _, target := range routed {
			host, _, _ := net.SplitHostPort(target)
			_ = exec.Command("route", "-n", "delete", "-inet6", "-host", host, "-interface", tun).Run()
		}
	}()
	results := make(chan bool, len(routed))
	for _, target := range routed {
		go func(target string) {
			conn, err := net.DialTimeout("tcp6", target, ipv6ProbeTimeout)
			if err == nil {
				conn.Close()
			}
			results <- err == nil
		}(target)
	}
	ok := false
	for range routed {
		if <-results {
			ok = true
		}
	}
	return ok
}
