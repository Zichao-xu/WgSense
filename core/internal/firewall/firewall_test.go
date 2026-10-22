package firewall

import (
	"path/filepath"
	"strings"
	"testing"
)

type fakeBackend struct {
	pf        string
	pfCalls   int
	hosts     []string
	hostCalls int
}

func (f *fakeBackend) ApplyPF(rules string) error { f.pf = rules; f.pfCalls++; return nil }
func (f *fakeBackend) ClearPF() error             { f.pf = ""; f.pfCalls++; return nil }
func (f *fakeBackend) ApplyHosts(d []string) error {
	f.hosts = d
	f.hostCalls++
	return nil
}

func newTest(t *testing.T, s Settings) (*Controller, *fakeBackend) {
	t.Helper()
	b := &fakeBackend{}
	c := New(filepath.Join(t.TempDir(), "firewall.json"), b, nil)
	c.PhysicalInterfaces = func() []string { return []string{"en0", "en7"} }
	c.TunnelEndpoints = func() []string { return []string{"1.2.3.4", "bad"} }
	if err := c.Update(s); err != nil {
		t.Fatal(err)
	}
	return c, b
}

func TestDisabledClearsEverything(t *testing.T) {
	c, b := newTest(t, Settings{})
	if err := c.Sync(Observation{}); err != nil {
		t.Fatal(err)
	}
	if b.pf != "" || b.hosts != nil || c.Status().Active {
		t.Fatalf("disabled should not block: pf=%q hosts=%v", b.pf, b.hosts)
	}
}

func TestAutoBlockAwayWithoutTunnel(t *testing.T) {
	c, b := newTest(t, Settings{AutoBlock: true})
	_ = c.Sync(Observation{Trusted: false, TunnelUp: false})
	if !c.Status().Active {
		t.Fatal("expected active")
	}
	if !strings.Contains(b.pf, "block return out quick on { en0 en7 } to <wgsense_ai>") {
		t.Fatalf("auto mode must be scoped to physical interfaces:\n%s", b.pf)
	}
	if strings.Contains(b.pf, "<wgsense_cn>") {
		t.Fatal("ai level must not load the CN table")
	}
	if len(b.hosts) == 0 {
		t.Fatal("hosts block expected while tunnel is down")
	}
}

func TestAutoBlockKeepsTunnelUsable(t *testing.T) {
	c, b := newTest(t, Settings{AutoBlock: true})
	_ = c.Sync(Observation{Trusted: false, TunnelUp: true})
	if b.pf == "" {
		t.Fatal("physical leak rules must stay while the tunnel is up")
	}
	if b.hosts != nil {
		t.Fatal("hosts would also block traffic through the tunnel")
	}
}

func TestTrustedNetworkLifts(t *testing.T) {
	c, b := newTest(t, Settings{AutoBlock: true})
	_ = c.Sync(Observation{Trusted: false})
	_ = c.Sync(Observation{Trusted: true})
	if b.pf != "" || b.hosts != nil || c.Status().Active {
		t.Fatal("trusted network should lift the block")
	}
}

func TestForceDomesticBlocksEverywhere(t *testing.T) {
	c, b := newTest(t, Settings{ForceDomestic: true, Level: LevelForeign})
	_ = c.Sync(Observation{Trusted: true, TunnelUp: true})
	st := c.Status()
	if !st.Active || !st.Forced {
		t.Fatalf("forced mode should be active: %+v", st)
	}
	if strings.Contains(b.pf, " on {") {
		t.Fatal("forced mode must cover all interfaces including the tunnel")
	}
	for _, want := range []string{"pass out quick to <wgsense_cn> no state", "table <wgsense_endpoint> const { 1.2.3.4 }", "block return out quick all"} {
		if !strings.Contains(b.pf, want) {
			t.Fatalf("missing %q in:\n%s", want, b.pf)
		}
	}
	if len(b.hosts) == 0 {
		t.Fatal("forced mode always uses the hosts block")
	}
}

func TestForeignYieldsToOtherVPN(t *testing.T) {
	c, b := newTest(t, Settings{AutoBlock: true, Level: LevelForeign})
	c.OtherVPNActive = func() bool { return true }
	_ = c.Sync(Observation{})
	if c.Status().Active || b.pf != "" {
		t.Fatal("foreign level should yield to another system VPN")
	}
}

func TestSyncIsIdempotent(t *testing.T) {
	c, b := newTest(t, Settings{AutoBlock: true})
	_ = c.Sync(Observation{})
	pf, hosts := b.pfCalls, b.hostCalls
	for i := 0; i < 3; i++ {
		_ = c.Sync(Observation{})
	}
	if b.pfCalls != pf || b.hostCalls != hosts {
		t.Fatal("unchanged state must not touch the system again")
	}
	c.PhysicalInterfaces = func() []string { return []string{"en0"} }
	_ = c.Sync(Observation{})
	if b.pfCalls != pf+1 {
		t.Fatal("interface change must reload pf")
	}
}

func TestSettingsPersist(t *testing.T) {
	path := filepath.Join(t.TempDir(), "firewall.json")
	c := New(path, &fakeBackend{}, nil)
	if err := c.Update(Settings{AutoBlock: true, Level: LevelForeign, AIDomains: []string{"https://Example.COM/path", "*.foo.ai", "bad", "example.com"}}); err != nil {
		t.Fatal(err)
	}
	got := New(path, &fakeBackend{}, nil).Settings()
	if !got.AutoBlock || got.Level != LevelForeign || strings.Join(got.AIDomains, ",") != "example.com,foo.ai" {
		t.Fatalf("unexpected settings: %+v", got)
	}
}

func TestRenderHostsRoundTrip(t *testing.T) {
	base := "127.0.0.1 localhost\n::1 localhost\n"
	blocked := RenderHosts(base, []string{"claude.ai"})
	if !strings.Contains(blocked, "0.0.0.0 claude.ai\n:: claude.ai\n") {
		t.Fatalf("missing entries:\n%s", blocked)
	}
	if again := RenderHosts(blocked, []string{"claude.ai"}); again != blocked {
		t.Fatal("render must be idempotent")
	}
	if cleared := RenderHosts(blocked, nil); cleared != base {
		t.Fatalf("clear must restore original:\n%q", cleared)
	}
}

func TestCNTableParses(t *testing.T) {
	if n := len(cnCIDRs()); n < 5000 {
		t.Fatalf("CN table looks truncated: %d", n)
	}
}
