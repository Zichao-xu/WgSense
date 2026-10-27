//go:build darwin && ipv6root

package tunnel

// 需要 root：go test -c -tags ipv6root 后 sudo 运行。会改动本机公网 IPv6 路由，
// 结束时删除。

import (
	"os/exec"
	"strings"
	"testing"
	"time"

	"golang.zx2c4.com/wireguard/tun"
)

func routeIface(t *testing.T, dst string) string {
	out, _ := exec.Command("route", "-n", "get", "-inet6", dst).CombinedOutput()
	s := string(out)
	if strings.Contains(s, "REJECT") {
		return "REJECT"
	}
	for _, line := range strings.Split(s, "\n") {
		if f := strings.Fields(line); len(f) == 2 && f[0] == "interface:" {
			return f[1]
		}
	}
	return s
}

func TestIPv6SwitchRealRoutes(t *testing.T) {
	dev, err := tun.CreateTUN("utun", 1420)
	if err != nil {
		t.Fatal(err)
	}
	defer dev.Close()
	name, _ := dev.Name()
	if err := configureInterface(name, "10.250.0.2/24"); err != nil {
		t.Fatal(err)
	}
	if err := configureInterface(name, autoIPv6Address("10.250.0.2/24")); err != nil {
		t.Fatal(err)
	}

	start := time.Now()
	if probeIPv6Via(name) {
		t.Fatal("peerless tunnel must not pass the IPv6 probe")
	}
	if d := time.Since(start); d > ipv6ProbeTimeout+time.Second {
		t.Fatalf("probe took %v", d)
	}
	if out, _ := exec.Command("netstat", "-rn", "-f", "inet6").Output(); strings.Contains(string(out), "2400:3200::1") {
		t.Fatal("probe host route left behind")
	}

	up := false
	s, err := startIPv6Switch(name)
	if err != nil {
		t.Fatal(err)
	}
	close(s.stop) // 停掉真实探测，改为手动驱动
	<-s.done
	s.stop, s.done = make(chan struct{}), make(chan struct{})
	close(s.done)
	s.probe = func() bool { return up }

	for _, dst := range []string{"2400:3200::1", "2a00:1450::1"} {
		if got := routeIface(t, dst); got != "REJECT" {
			t.Fatalf("%s initially = %s, want REJECT", dst, got)
		}
	}
	up = true
	s.check()
	for _, dst := range []string{"2400:3200::1", "2a00:1450::1"} {
		if got := routeIface(t, dst); got != name {
			t.Fatalf("%s via tunnel = %s, want %s", dst, got, name)
		}
	}
	up = false
	s.check()
	if got := routeIface(t, "2400:3200::1"); got != "REJECT" {
		t.Fatalf("fallback = %s, want REJECT", got)
	}
	if got := routeIface(t, "fe80::1%lo0"); got == "REJECT" {
		t.Fatal("link-local must not be rejected")
	}
	out, _ := exec.Command("netstat", "-rn", "-f", "inet6").Output()
	for _, guard := range ipv6GuardRoutes {
		if strings.Contains(string(out), "\n"+guard+" ") {
			t.Fatalf("guard route %s left behind", guard)
		}
	}
	s.close()
	out, _ = exec.Command("netstat", "-rn", "-f", "inet6").Output()
	if strings.Contains(string(out), "\n::/1 ") || strings.Contains(string(out), "\n8000::/1 ") {
		t.Fatal("public IPv6 routes left after close")
	}
}
