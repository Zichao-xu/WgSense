//go:build darwin

package tunnel

import (
	"errors"
	"reflect"
	"sync"
	"testing"
	"time"
)

func TestIsFullTunnel(t *testing.T) {
	for _, allowed := range [][]string{{"0.0.0.0/0"}, {" ::/0"}, {"10.0.0.0/8", "0.0.0.0/0"}} {
		if !isFullTunnel(allowed) {
			t.Fatalf("%v should be a full tunnel", allowed)
		}
	}
	if isFullTunnel([]string{"10.10.1.0/24", "fd00::/8"}) {
		t.Fatal("split tunnel must not take over public IPv6")
	}
}

func TestAutoIPv6Address(t *testing.T) {
	if got := autoIPv6Address("10.66.66.3/24"); got != "fd77:6773::10.66.66.3/96" {
		t.Fatalf("auto = %q", got)
	}
	if got := autoIPv6Address("fd00::3/64, 10.66.66.11/32"); got != "fd77:6773::10.66.66.11/96" {
		t.Fatalf("auto from mixed = %q", got)
	}
	if got := autoIPv6Address("fd00::3/64"); got != "" {
		t.Fatalf("no IPv4 should give no auto address, got %q", got)
	}
}

func TestEnsureAllowedIPv6(t *testing.T) {
	if got := ensureAllowedIPv6([]string{"0.0.0.0/0"}); !reflect.DeepEqual(got, []string{"0.0.0.0/0", "::/0"}) {
		t.Fatalf("got %#v", got)
	}
	if got := ensureAllowedIPv6([]string{"0.0.0.0/0", "::/0"}); len(got) != 2 {
		t.Fatalf("must not duplicate ::/0: %#v", got)
	}
}

// fakeSwitch 不碰系统路由，记录每次安装的方向。
func fakeSwitch(probe func() bool) (*ipv6Switch, *[]bool, *sync.Mutex) {
	var mu sync.Mutex
	var installs []bool
	s := &ipv6Switch{tun: "utun99", probe: probe, stop: make(chan struct{}), done: make(chan struct{})}
	s.install = func(via bool) error {
		mu.Lock()
		defer mu.Unlock()
		installs = append(installs, via)
		return nil
	}
	return s, &installs, &mu
}

func TestIPv6SwitchFollowsProbe(t *testing.T) {
	up := false
	s, installs, mu := fakeSwitch(func() bool { return up })

	s.check() // 隧道没有 IPv6：保持拒绝，不重复安装
	if s.viaTunnel() || len(*installs) != 0 {
		t.Fatalf("unreachable IPv6 must stay rejected, installs=%v", *installs)
	}
	up = true
	s.check() // 服务器开了 IPv6：切进隧道
	if !s.viaTunnel() {
		t.Fatal("reachable IPv6 should switch into the tunnel")
	}
	s.check() // 状态不变不重装
	up = false
	s.check() // 又不通了：退回拒绝
	if s.viaTunnel() {
		t.Fatal("lost IPv6 should fall back to reject")
	}
	mu.Lock()
	defer mu.Unlock()
	if !reflect.DeepEqual(*installs, []bool{true, false}) {
		t.Fatalf("installs = %v", *installs)
	}
}

func TestIPv6SwitchKeepsStateWhenInstallFails(t *testing.T) {
	s, _, _ := fakeSwitch(func() bool { return true })
	s.install = func(bool) error { return errors.New("route failed") }
	s.check()
	if s.viaTunnel() {
		t.Fatal("state must not flip when routes failed to install")
	}
}

func TestIPv6SwitchLoopStopsPromptly(t *testing.T) {
	probes := make(chan struct{}, 4)
	s, _, _ := fakeSwitch(func() bool { probes <- struct{}{}; return false })
	go s.loop()
	select {
	case <-probes:
	case <-time.After(time.Second):
		t.Fatal("first probe should run immediately")
	}
	close(s.stop)
	select {
	case <-s.done:
	case <-time.After(time.Second):
		t.Fatal("loop did not stop")
	}
}
