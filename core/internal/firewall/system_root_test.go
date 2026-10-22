//go:build pfroot

// 实机测试：需要 root，会短暂修改 pf 与 /etc/hosts，结束时还原。
// 前提：WG 全局隧道已连接且不在受信任网络，自动模式只拦物理网卡，不影响走隧道的会话。
//
//	go test -c -tags pfroot -o fw.test ./internal/firewall && sudo ./fw.test -test.v
package firewall

import (
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const (
	// 用一个国内 IP 冒充 AI 目标：直连基线可达，才能证明是 pf 挡的。
	// 不用真实 Anthropic IP，避免把本机走隧道的 Claude 会话改道到 en0。
	fakeAIIP   = "111.63.65.103"
	cnIP       = "110.242.74.102" // baidu.com
	foreignIP  = "1.1.1.1"
	testDomain = "wgsense-selftest.example.org"
)

// leakRoutes 给测试 IP 加走物理网关的主机路由，模拟"绕过 WG 的直连"。
func leakRoutes(t *testing.T) (string, func()) {
	out, _ := exec.Command("/sbin/route", "-n", "get", "-ifscope", "en0", "default").CombinedOutput()
	if !strings.Contains(string(out), "interface: en0") {
		out, _ = exec.Command("/sbin/route", "-n", "get", "default").CombinedOutput()
	}
	var gw string
	for _, line := range strings.Split(string(out), "\n") {
		if k, v, ok := strings.Cut(strings.TrimSpace(line), ":"); ok && k == "gateway" {
			gw = strings.TrimSpace(v)
		}
	}
	if net.ParseIP(gw) == nil {
		t.Skipf("找不到物理网关: %s", out)
	}
	ips := []string{fakeAIIP, cnIP, foreignIP}
	for _, ip := range ips {
		_ = exec.Command("/sbin/route", "-n", "add", "-host", ip, gw).Run()
	}
	return "en0", func() {
		for _, ip := range ips {
			_ = exec.Command("/sbin/route", "-n", "delete", "-host", ip).Run()
		}
	}
}

func dial(ip string) (time.Duration, error) {
	start := time.Now()
	err := exec.Command("/usr/bin/curl", "-s", "-o", "/dev/null", "-m", "5", "http://"+ip).Run()
	return time.Since(start), err
}

// expectRejected 要求连接被 pf 的 block return 秒拒，而不是超时(超时可能是墙)。
func expectRejected(t *testing.T, ip string) {
	t.Helper()
	took, err := dial(ip)
	if err == nil {
		t.Fatalf("%s 应被拦截", ip)
	}
	if took > 1500*time.Millisecond {
		t.Fatalf("%s 失败但用了 %s，不像 pf 秒拒", ip, took)
	}
	t.Logf("%s 被拒，用时 %s", ip, took.Round(time.Millisecond))
}

func expectReachable(t *testing.T, ip string) {
	t.Helper()
	if _, err := dial(ip); err != nil {
		t.Fatalf("%s 应可达: %v", ip, err)
	}
}

func tunnelAlive() error {
	return exec.Command("/usr/bin/curl", "-s", "-o", "/dev/null", "-m", "6", "https://api.anthropic.com").Run()
}

func TestRootSystemBackend(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("需要 root")
	}
	iface, restoreRoutes := leakRoutes(t)
	defer restoreRoutes()
	savedCIDRs := aiCIDRs
	aiCIDRs = append([]string{fakeAIIP + "/32"}, aiCIDRs...)
	defer func() { aiCIDRs = savedCIDRs }()
	hostsBefore, _ := os.ReadFile(hostsPath)
	sys := System{}
	c := New(filepath.Join(t.TempDir(), "firewall.json"), sys, t.Logf)
	c.PhysicalInterfaces = func() []string { return []string{iface} }
	defer func() {
		if err := ClearAll(sys); err != nil {
			t.Errorf("清理失败: %v", err)
		}
		after, _ := os.ReadFile(hostsPath)
		if string(after) != string(hostsBefore) {
			t.Errorf("hosts 未还原")
		}
		// 只看 stdout：pfctl 会往 stderr 打 "No ALTQ support" 之类的提示。
		out, _ := exec.Command(pfctl, "-a", Anchor, "-s", "rules").Output()
		if strings.TrimSpace(string(out)) != "" {
			t.Errorf("锚点未清空: %s", out)
		}
		if _, err := os.Stat(tokenPath()); err == nil {
			t.Errorf("pf 令牌未归还")
		}
	}()

	expectReachable(t, fakeAIIP)
	expectReachable(t, cnIP)
	_, foreignErr := dial(foreignIP)
	t.Logf("基线：直连 %s 可达=%t", foreignIP, foreignErr == nil)

	t.Run("AI档：直连 Anthropic 被拦，隧道照常", func(t *testing.T) {
		if err := c.Update(Settings{AutoBlock: true, Level: LevelAI}); err != nil {
			t.Fatal(err)
		}
		if err := c.Sync(Observation{Trusted: false, TunnelUp: true}); err != nil {
			t.Fatal(err)
		}
		expectRejected(t, fakeAIIP)
		expectReachable(t, cnIP)
		if err := tunnelAlive(); err != nil {
			t.Fatalf("走隧道访问 api.anthropic.com 应正常: %v", err)
		}
	})

	t.Run("境外档：直连境外被拦、国内放行", func(t *testing.T) {
		if err := c.Update(Settings{AutoBlock: true, Level: LevelForeign}); err != nil {
			t.Fatal(err)
		}
		expectRejected(t, foreignIP)
		expectReachable(t, cnIP)
		if err := tunnelAlive(); err != nil {
			t.Fatalf("隧道应不受影响: %v", err)
		}
	})

	t.Run("隧道断开时 hosts 域名拦截", func(t *testing.T) {
		if err := c.Update(Settings{AutoBlock: true, Level: LevelAI, AIDomains: []string{testDomain}}); err != nil {
			t.Fatal(err)
		}
		if err := c.Sync(Observation{Trusted: false, TunnelUp: false}); err != nil {
			t.Fatal(err)
		}
		addrs, _ := net.LookupHost(testDomain)
		if len(addrs) == 0 || (addrs[0] != "0.0.0.0" && addrs[0] != "::") {
			t.Fatalf("hosts 拦截未生效: %v", addrs)
		}
		if err := c.Sync(Observation{Trusted: false, TunnelUp: true}); err != nil {
			t.Fatal(err)
		}
		data, _ := os.ReadFile(hostsPath)
		if strings.Contains(string(data), testDomain) {
			t.Fatal("隧道恢复后 hosts 段应移除")
		}
	})

	t.Run("受信任网络解除", func(t *testing.T) {
		if err := c.Sync(Observation{Trusted: true}); err != nil {
			t.Fatal(err)
		}
		expectReachable(t, fakeAIIP)
	})
}
