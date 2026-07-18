//go:build darwin

package tunnel

import (
	"net"
	"reflect"
	"testing"
)

func TestPlannedTunnelRoutesIPv4Only(t *testing.T) {
	got := plannedTunnelRoutes([]string{"0.0.0.0/0", "::/0", "10.20.0.0/16", "2001:db8::/32"}, false)
	want := []string{"0/1", "128.0/1", "10.20.0.0/16"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("routes = %#v, want %#v", got, want)
	}
}

func TestPlannedTunnelRoutesDualStack(t *testing.T) {
	got := plannedTunnelRoutes([]string{"0.0.0.0/0", "::/0"}, true)
	want := []string{"0/1", "128.0/1", "::/1", "8000::/1"}
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
