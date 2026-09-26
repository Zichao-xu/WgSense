package tunnel

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"testing"
)

const officialWireGuardService = `* (%s) E3B030D2-6CC2-4B13-B49D-A4AED14897B9 VPN (com.wireguard.macos) "WgSense-default" [VPN:com.wireguard.macos]`

func TestActiveSystemVPNsProtectsOfficialWireGuard(t *testing.T) {
	for _, state := range []string{"Connected", "Connecting", "Disconnecting", "Reasserting"} {
		t.Run(state, func(t *testing.T) {
			got := activeSystemVPNs(fmt.Sprintf(officialWireGuardService, state))
			want := []systemVPN{{Name: "WgSense-default", State: state}}
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("active VPNs = %#v, want %#v", got, want)
			}
		})
	}
}

func TestActiveSystemVPNsAllowsInactiveServices(t *testing.T) {
	output := "Available network connection services in the current set (*=enabled):\n" +
		fmt.Sprintf(officialWireGuardService, "Disconnected") + "\n" +
		`* (Disconnected) 889A0858-ABA9-4A74-BEFF-07E410129FC5 VPN (com.liguangming.Shadowrocket) "Shadowrocket" [VPN:com.liguangming.Shadowrocket]`
	if got := activeSystemVPNs(output); len(got) != 0 {
		t.Fatalf("inactive VPNs blocked connection: %#v", got)
	}
}

func TestActiveSystemVPNsIgnoresOrdinaryUtunAndModem(t *testing.T) {
	output := `utun0: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1380
utun1: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 2000
* (Connected) 6A6CEBF8-05D7-4E2D-A9D6-4EBCA9E441CE PPP --> USB CDC-Serial "USB CDC-Serial" [PPP:Modem]`
	if got := activeSystemVPNs(output); len(got) != 0 {
		t.Fatalf("ordinary interfaces or a modem mistaken for VPN: %#v", got)
	}
}

func TestCheckSystemVPNsOnlyRunsReadOnlyList(t *testing.T) {
	var calls int
	err := checkSystemVPNs(func(ctx context.Context, name string, args ...string) ([]byte, error) {
		calls++
		if name != "/usr/sbin/scutil" || !reflect.DeepEqual(args, []string{"--nc", "list"}) {
			t.Fatalf("unexpected command: %s %v", name, args)
		}
		if _, ok := ctx.Deadline(); !ok {
			t.Fatal("system VPN query has no deadline")
		}
		return []byte(fmt.Sprintf(officialWireGuardService, "Connected")), nil
	})
	if calls != 1 || err == nil || !strings.Contains(err.Error(), "WgSense-default（Connected）") {
		t.Fatalf("active VPN guard: calls=%d, err=%v", calls, err)
	}
}

func TestCheckSystemVPNsFailsClosedOnQueryFailure(t *testing.T) {
	want := errors.New("system query failed")
	err := checkSystemVPNs(func(context.Context, string, ...string) ([]byte, error) {
		return nil, want
	})
	if !errors.Is(err, want) {
		t.Fatalf("query failure = %v, want wrapped %v", err, want)
	}
}

func TestCheckSystemVPNsAllowsNoActiveVPN(t *testing.T) {
	err := checkSystemVPNs(func(context.Context, string, ...string) ([]byte, error) {
		return []byte(fmt.Sprintf(officialWireGuardService, "Disconnected")), nil
	})
	if err != nil {
		t.Fatalf("disconnected VPN should not block WgSense: %v", err)
	}
}
