package firewall

import (
	"path/filepath"
	"strings"
	"testing"
)

type fakeBackend struct {
	pf          string
	pfCalls     int
	hostsClears int
}

func (f *fakeBackend) ApplyPF(rules string) error { f.pf = rules; f.pfCalls++; return nil }
func (f *fakeBackend) ClearPF() error             { f.pf = ""; f.pfCalls++; return nil }
func (f *fakeBackend) RemoveLegacyHosts() error   { f.hostsClears++; return nil }

func newTest(t *testing.T, s Settings) (*Controller, *fakeBackend) {
	t.Helper()
	b := &fakeBackend{}
	c := New(filepath.Join(t.TempDir(), "firewall.json"), b, nil)
	c.PhysicalInterfaces = func() []string { return []string{"en7", "en0"} }
	c.ActiveInterfaces = func() []string { return []string{"en0"} }
	c.TunnelEndpoints = func() []string { return []string{"1.2.3.4", "bad"} }
	if err := c.Update(s); err != nil {
		t.Fatal(err)
	}
	return c, b
}

func TestDisabledClearsEverything(t *testing.T) {
	c, b := newTest(t, Settings{})
	if b.pf != "" || c.Status().Active {
		t.Fatalf("disabled should not block: %q", b.pf)
	}
	if b.hostsClears != 1 {
		t.Fatal("first sync must remove the v1.0.4 hosts section")
	}
}

func TestBlockScopesPhysicalInterfaces(t *testing.T) {
	c, b := newTest(t, Settings{Block: true})
	st := c.Status()
	if !st.Active || st.Forced || strings.Join(st.Interfaces, ",") != "en0" {
		t.Fatalf("unexpected status: %+v", st)
	}
	for _, want := range []string{
		"198.18.0.0/15", "1.2.3.4", "fe80::/10",
		"pass out quick on { en0 en7 } to <wgsense_allow> no state",
		"pass out quick on { en0 en7 } to <wgsense_cn> no state",
		"block return out quick on { en0 en7 } all",
	} {
		if !strings.Contains(b.pf, want) {
			t.Fatalf("missing %q in:\n%s", want, b.pf)
		}
	}
}

func TestForceDomesticCoversTunnelAndProxy(t *testing.T) {
	c, b := newTest(t, Settings{Block: true, ForceDomestic: true})
	if !c.Status().Forced {
		t.Fatal("expected forced")
	}
	if strings.Contains(b.pf, " on {") {
		t.Fatal("domestic mode must cover every interface including the tunnel")
	}
	if strings.Contains(b.pf, "198.18.0.0/15") {
		t.Fatal("domestic mode must not let fake-ip traffic reach the gateway proxy")
	}
	if !strings.Contains(b.pf, "block return out quick all") {
		t.Fatalf("missing global block:\n%s", b.pf)
	}
}

func TestSyncIsIdempotent(t *testing.T) {
	c, b := newTest(t, Settings{Block: true})
	calls := b.pfCalls
	for i := 0; i < 3; i++ {
		_ = c.Sync()
	}
	if b.pfCalls != calls || b.hostsClears != 1 {
		t.Fatal("unchanged state must not touch the system again")
	}
	c.PhysicalInterfaces = func() []string { return []string{"en0"} }
	_ = c.Sync()
	if b.pfCalls != calls+1 {
		t.Fatal("interface change must reload pf")
	}
}

func TestSettingsPersistAndKeepV104Switch(t *testing.T) {
	path := filepath.Join(t.TempDir(), "firewall.json")
	c := New(path, &fakeBackend{}, nil)
	if err := c.Update(Settings{Block: true}); err != nil {
		t.Fatal(err)
	}
	if got := New(path, &fakeBackend{}, nil).Settings(); !got.Block {
		t.Fatalf("setting lost: %+v", got)
	}
}

func TestStripLegacyHosts(t *testing.T) {
	base := "127.0.0.1 localhost\n::1 localhost\n"
	if stripLegacyHosts(base) != base {
		t.Fatal("hosts without our section must stay byte-identical")
	}
	legacy := base + hostsBegin + "\n0.0.0.0 claude.ai\n:: claude.ai\n" + hostsEnd + "\n"
	if got := stripLegacyHosts(legacy); got != base {
		t.Fatalf("legacy section not removed:\n%q", got)
	}
}

func TestCNTableParses(t *testing.T) {
	v6 := 0
	for _, cidr := range cnCIDRs() {
		if strings.Contains(cidr, ":") {
			v6++
		}
	}
	if n := len(cnCIDRs()); n < 5000 || v6 < 1000 {
		t.Fatalf("CN table looks truncated: total=%d v6=%d", n, v6)
	}
}
