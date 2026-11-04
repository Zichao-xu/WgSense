//go:build darwin

package tunnel

import (
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"

	"github.com/wgsense/core/internal/config"
)

func TestPlannedTunnelRoutesIPv4Only(t *testing.T) {
	got := plannedTunnelRoutes([]string{"0.0.0.0/0", "::/0", "10.20.0.0/16", "2001:db8::/32"}, false)
	want := []string{"0/1", "128.0/1", "10.20.0.0/16"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("routes = %#v, want %#v", got, want)
	}
}

func TestPlannedTunnelRoutesLeavesPublicIPv6ToSwitch(t *testing.T) {
	got := plannedTunnelRoutes([]string{"0.0.0.0/0", "::/0", "fd00:1::/64"}, true)
	want := []string{"0/1", "128.0/1", "fd00:1::/64"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("routes = %#v, want %#v", got, want)
	}
}

func TestPlannedTunnelRoutesDoesNotInventFakeIPExclusion(t *testing.T) {
	got := plannedTunnelRoutes([]string{"0.0.0.0/0"}, false)
	for _, route := range got {
		if route == "198.18.0.0/15" {
			t.Fatal("Fake-IP must remain owned by the proxy route")
		}
	}
}

func TestIsFakeIP(t *testing.T) {
	for _, ip := range []string{"198.18.0.1", "198.19.255.254"} {
		if !isFakeIP(net.ParseIP(ip)) {
			t.Fatalf("%s should be treated as proxy fake-ip", ip)
		}
	}
	for _, ip := range []string{"198.20.0.1", "1.1.1.1", "10.66.66.1"} {
		if isFakeIP(net.ParseIP(ip)) {
			t.Fatalf("%s should not be treated as proxy fake-ip", ip)
		}
	}
}

func TestParseDNSServers(t *testing.T) {
	got := parseDNSServers("10.66.66.1, 1.1.1.1\n8.8.8.8")
	want := []string{"10.66.66.1", "1.1.1.1", "8.8.8.8"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("dns servers = %#v, want %#v", got, want)
	}
}

func TestParseNetworkServiceForInterface(t *testing.T) {
	output := `Hardware Port: Wi-Fi
Device: en0
Ethernet Address: 00:11:22:33:44:55

Hardware Port: USB 10/100/1000 LAN
Device: en4
Ethernet Address: aa:bb:cc:dd:ee:ff
`
	got, err := parseNetworkServiceForInterface(output, "en4")
	if err != nil {
		t.Fatal(err)
	}
	if got != "USB 10/100/1000 LAN" {
		t.Fatalf("service = %q", got)
	}
}

func TestParseCurrentDNSServers(t *testing.T) {
	got := parseCurrentDNSServers("10.10.1.1\n1.1.1.1\n")
	want := []string{"10.10.1.1", "1.1.1.1"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("current dns = %#v, want %#v", got, want)
	}

	if got := parseCurrentDNSServers("There aren't any DNS Servers set on Wi-Fi.\n"); got != nil {
		t.Fatalf("empty dns = %#v, want nil", got)
	}
}

func TestNetworkOf(t *testing.T) {
	if got := networkOf("192.168.2.23/24"); got != "192.168.2.0/24" {
		t.Fatalf("got %q", got)
	}
	if got := networkOf("not-a-cidr"); got != "not-a-cidr" {
		t.Fatalf("got %q", got)
	}
}

func writeProfiles(t *testing.T, names ...string) string {
	t.Helper()
	dir := t.TempDir()
	for _, name := range names {
		if err := os.WriteFile(filepath.Join(dir, name), nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func TestResolveProfilePathPrefersService(t *testing.T) {
	dir := writeProfiles(t, "default.conf", "friend.conf")
	got, err := resolveProfilePath(dir, "default")
	if err != nil || got != filepath.Join(dir, "default.conf") {
		t.Fatalf("got %q, %v", got, err)
	}
}

func TestResolveProfilePathFallsBackToOnlyProfile(t *testing.T) {
	dir := writeProfiles(t, "friend.conf", "notes.txt")
	got, err := resolveProfilePath(dir, "default")
	if err != nil || got != filepath.Join(dir, "friend.conf") {
		t.Fatalf("got %q, %v", got, err)
	}
}

func TestResolveProfilePathRefusesToGuess(t *testing.T) {
	dir := writeProfiles(t, "a.conf", "b.conf")
	if _, err := resolveProfilePath(dir, "default"); err == nil || !strings.Contains(err.Error(), "切换") {
		t.Fatalf("err = %v", err)
	}
}

func TestResolveProfilePathEmpty(t *testing.T) {
	for _, dir := range []string{t.TempDir(), filepath.Join(t.TempDir(), "missing")} {
		if _, err := resolveProfilePath(dir, "default"); err == nil || !strings.Contains(err.Error(), "导入") {
			t.Fatalf("%s: err = %v", dir, err)
		}
	}
}

func TestCheckProfileComplete(t *testing.T) {
	if err := checkProfileComplete(&config.Profile{}); err == nil {
		t.Fatal("空配置应报错")
	}
	full := &config.Profile{Peers: []config.PeerConfig{{}}}
	full.Interface.PrivateKey = "k"
	if err := checkProfileComplete(full); err != nil {
		t.Fatal(err)
	}
}

func TestSaveProfileFollowsDirOwnerAsRoot(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("需要 root")
	}
	dir := t.TempDir()
	if err := os.Chown(dir, 501, 20); err != nil {
		t.Fatal(err)
	}
	m := &darwinManager{configDir: dir}
	if err := m.SaveProfile("friend", "x"); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(filepath.Join(dir, "friend.conf"))
	if err != nil {
		t.Fatal(err)
	}
	if uid := info.Sys().(*syscall.Stat_t).Uid; uid != 501 {
		t.Fatalf("uid = %d", uid)
	}
}
