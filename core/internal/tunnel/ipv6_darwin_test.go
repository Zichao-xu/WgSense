//go:build darwin

package tunnel

import (
	"errors"
	"path/filepath"
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
	const prefix = "fd77:6773::"
	if got := autoIPv6Address(prefix, "10.66.66.3/24"); got != "fd77:6773::a42:4203/96" {
		t.Fatalf("auto = %q", got)
	}
	if got := autoIPv6Address(prefix, "fd00::3/64, 10.66.66.11/32"); got != "fd77:6773::a42:420b/96" {
		t.Fatalf("auto from mixed = %q", got)
	}
	if got := autoIPv6Address(prefix, "fd00::3/64"); got != "" {
		t.Fatalf("no IPv4 should give no auto address, got %q", got)
	}
	if got := autoIPv6Address("2001:db8::", "10.66.66.3/24"); got != "" {
		t.Fatalf("public prefix must be refused, got %q", got)
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

func TestIPv6SettingsValidate(t *testing.T) {
	if err := DefaultIPv6Settings().Validate(); err != nil {
		t.Fatalf("defaults invalid: %v", err)
	}
	bad := []IPv6Settings{
		{Mode: "sometimes", Prefix: "fd77:6773::"},
		{Mode: IPv6ModeAuto, Prefix: "fd77:6773"},
		{Mode: IPv6ModeAuto, Prefix: "2001:db8::"},
		{Mode: IPv6ModeAuto, Prefix: "fd77::", ProbeTargets: []string{"1.1.1.1:53"}},
		{Mode: IPv6ModeAuto, Prefix: "fd77::", ProbeTargets: []string{"[2400:3200::1]"}},
	}
	for _, s := range bad {
		if s.Validate() == nil {
			t.Fatalf("%+v should be rejected", s)
		}
	}
}

func TestIPv6SettingsPersist(t *testing.T) {
	path := filepath.Join(t.TempDir(), "tunnel-ipv6.json")
	if got := LoadIPv6Settings(path); !reflect.DeepEqual(got, DefaultIPv6Settings()) {
		t.Fatalf("missing file should load defaults: %+v", got)
	}
	want := IPv6Settings{Mode: IPv6ModeBlock, Prefix: "fd00:1::", ProbeTargets: []string{"[2400:3200::1]:443"}}
	if err := SaveIPv6Settings(path, want); err != nil {
		t.Fatal(err)
	}
	if got := LoadIPv6Settings(path); !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v", got)
	}
}

// fakeSwitch 不碰系统路由，记录每次安装的方向。
func fakeSwitch(probe func() bool) (*ipv6Switch, *[]bool, *sync.Mutex) {
	var mu sync.Mutex
	var installs []bool
	s := newIPv6Switch("utun99", func() []string { return []string{"[2400:3200::1]:53"} })
	s.probe = func([]string) bool { return probe() }
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
	stop := make(chan struct{})

	if st := s.status(); st.State != IPv6StateProbing {
		t.Fatalf("before first probe = %s", st.State)
	}
	s.check(stop) // 隧道没有 IPv6：保持拒绝，不重复安装
	if st := s.status(); st.State != IPv6StateBlocked || st.LastProbe == "" || st.LastProbeOK {
		t.Fatalf("unreachable IPv6 status = %+v", st)
	}
	up = true
	s.check(stop) // 服务器开了 IPv6：切进隧道
	if st := s.status(); st.State != IPv6StateTunnel || !st.LastProbeOK {
		t.Fatalf("reachable IPv6 status = %+v", st)
	}
	s.check(stop) // 状态不变不重装
	up = false
	s.check(stop) // 又不通了：退回拒绝
	if s.status().State != IPv6StateBlocked {
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
	s.check(make(chan struct{}))
	if st := s.status(); st.State == IPv6StateTunnel || st.Error == "" {
		t.Fatalf("failed install must keep reject and report error: %+v", st)
	}
}

func TestIPv6SwitchBlockModeSkipsProbe(t *testing.T) {
	probed := false
	s, installs, mu := fakeSwitch(func() bool { probed = true; return true })
	if err := s.start(true); err != nil {
		t.Fatal(err)
	}
	time.Sleep(50 * time.Millisecond)
	if probed {
		t.Fatal("block mode must not probe")
	}
	if st := s.status(); st.Mode != IPv6ModeBlock || st.State != IPv6StateBlocked {
		t.Fatalf("status = %+v", st)
	}
	mu.Lock()
	if !reflect.DeepEqual(*installs, []bool{false}) {
		t.Fatalf("installs = %v", *installs)
	}
	mu.Unlock()
	s.close()
}

func TestIPv6SwitchLiveModeChange(t *testing.T) {
	probes := make(chan struct{}, 8)
	s, installs, mu := fakeSwitch(func() bool { probes <- struct{}{}; return true })
	if err := s.start(false); err != nil {
		t.Fatal(err)
	}
	select {
	case <-probes:
	case <-time.After(time.Second):
		t.Fatal("auto mode should probe immediately")
	}
	deadline := time.Now().Add(time.Second)
	for s.status().State != IPv6StateTunnel && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	s.setBlock(true) // 用户改成始终拒绝：立即退回拒绝
	if st := s.status(); st.State != IPv6StateBlocked || st.Mode != IPv6ModeBlock {
		t.Fatalf("after block = %+v", st)
	}
	s.setBlock(false) // 改回自动：重新探测
	select {
	case <-probes:
	case <-time.After(time.Second):
		t.Fatal("auto mode should probe again")
	}
	s.close()
	mu.Lock()
	defer mu.Unlock()
	if len(*installs) < 3 || (*installs)[0] != false || (*installs)[1] != true || (*installs)[2] != false {
		t.Fatalf("installs = %v", *installs)
	}
}
