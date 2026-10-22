//go:build pfroot

// 实机测试：需要 root，会短暂修改 pf 与 /etc/hosts，结束时还原。
// 前提：WG 全局隧道已连接，本机会话走隧道，拦截只作用于物理网卡。
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
	cnIP      = "110.242.74.102" // baidu.com
	foreignIP = "1.1.1.1"
	cnIP6     = "2400:3200::1" // 阿里 DNS
	foreignV6 = "2620:fe::fe"  // Quad9
)

// leakRoutes 给 IPv4 测试地址加走物理网关的主机路由，模拟"绕过 WG 的直连"。
// IPv6 本来就不进隧道，无需加路由。
func leakRoutes(t *testing.T) func() {
	out, _ := exec.Command("/sbin/route", "-n", "get", "default").CombinedOutput()
	var gw string
	for _, line := range strings.Split(string(out), "\n") {
		if k, v, ok := strings.Cut(strings.TrimSpace(line), ":"); ok && k == "gateway" {
			gw = strings.TrimSpace(v)
		}
	}
	if net.ParseIP(gw) == nil {
		t.Skipf("找不到物理网关: %s", out)
	}
	ips := []string{cnIP, foreignIP}
	for _, ip := range ips {
		_ = exec.Command("/sbin/route", "-n", "add", "-host", ip, gw).Run()
	}
	return func() {
		for _, ip := range ips {
			_ = exec.Command("/sbin/route", "-n", "delete", "-host", ip).Run()
		}
	}
}

func dial(host string) (time.Duration, error) {
	if strings.Contains(host, ":") {
		host = "[" + host + "]"
	}
	start := time.Now()
	err := exec.Command("/usr/bin/curl", "-gks", "-o", "/dev/null", "-m", "5", "http://"+host).Run()
	return time.Since(start), err
}

// expectRejected 要求连接被 pf 的 block return 秒拒，而不是超时(超时可能是墙)。
func expectRejected(t *testing.T, host string) {
	t.Helper()
	took, err := dial(host)
	if err == nil {
		t.Fatalf("%s 应被拦截", host)
	}
	if took > 1500*time.Millisecond {
		t.Fatalf("%s 失败但用了 %s，不像 pf 秒拒", host, took)
	}
	t.Logf("%s 被拒，用时 %s", host, took.Round(time.Millisecond))
}

func expectReachable(t *testing.T, host string) {
	t.Helper()
	if _, err := dial(host); err != nil {
		t.Fatalf("%s 应可达: %v", host, err)
	}
}

func tunnelAlive() error {
	return exec.Command("/usr/bin/curl", "-s", "-o", "/dev/null", "-m", "6", "https://api.anthropic.com").Run()
}

func TestRootSystemBackend(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("需要 root")
	}
	sys := System{}
	hostsBefore, _ := os.ReadFile(hostsPath)
	if err := ClearAll(sys); err != nil {
		t.Fatal(err)
	}
	defer leakRoutes(t)()
	defer func() {
		if err := ClearAll(sys); err != nil {
			t.Errorf("清理失败: %v", err)
		}
		if after, _ := os.ReadFile(hostsPath); string(after) != string(hostsBefore) {
			t.Errorf("hosts 未还原")
		}
		// 只看 stdout：pfctl 会往 stderr 打 "No ALTQ support" 之类的提示。
		if out, _ := exec.Command(pfctl, "-a", Anchor, "-s", "rules").Output(); strings.TrimSpace(string(out)) != "" {
			t.Errorf("锚点未清空: %s", out)
		}
		if _, err := os.Stat(tokenPath()); err == nil {
			t.Errorf("pf 令牌未归还")
		}
	}()

	_, foreignErr := dial(foreignIP)
	_, foreign6Err := dial(foreignV6)
	t.Logf("基线：%s 可达=%t，%s 可达=%t", foreignIP, foreignErr == nil, foreignV6, foreign6Err == nil)
	expectReachable(t, cnIP)
	expectReachable(t, cnIP6)

	// 放一段 v1.0.4 风格的 hosts 遗留，确认首次同步会清掉。
	legacy := strings.TrimRight(string(hostsBefore), "\n") + "\n" + hostsBegin + "\n0.0.0.0 wgsense-selftest.example.org\n" + hostsEnd + "\n"
	if err := os.WriteFile(hostsPath, []byte(legacy), 0644); err != nil {
		t.Fatal(err)
	}

	c := New(filepath.Join(t.TempDir(), "firewall.json"), sys, t.Logf)
	c.PhysicalInterfaces = func() []string { return []string{"en0"} }
	if err := c.Update(Settings{Block: true}); err != nil {
		t.Fatal(err)
	}
	if data, _ := os.ReadFile(hostsPath); strings.Contains(string(data), hostsBegin) {
		t.Fatal("v1.0.4 hosts 遗留未清理")
	}

	t.Run("境外 IPv4/IPv6 直连秒拒", func(t *testing.T) {
		expectRejected(t, foreignIP)
		expectRejected(t, foreignV6)
	})
	t.Run("国内 IPv4/IPv6 照常", func(t *testing.T) {
		expectReachable(t, cnIP)
		expectReachable(t, cnIP6)
	})
	t.Run("走 WG 隧道不受影响", func(t *testing.T) {
		if err := tunnelAlive(); err != nil {
			t.Fatalf("走隧道访问 api.anthropic.com 应正常: %v", err)
		}
	})
	t.Run("关闭即放行", func(t *testing.T) {
		if err := c.Update(Settings{}); err != nil {
			t.Fatal(err)
		}
		expectReachable(t, cnIP)
		if out, _ := exec.Command(pfctl, "-a", Anchor, "-s", "rules").Output(); strings.TrimSpace(string(out)) != "" {
			t.Fatalf("关闭后锚点应为空: %s", out)
		}
	})
}
