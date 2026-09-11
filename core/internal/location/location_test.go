package location

import "testing"

func TestSelectActiveInterfacesPrefersFastWiredBeforeWiFi(t *testing.T) {
	got := selectActiveInterfaces(
		map[string][]string{
			"en0":   {"10.125.171.66"},
			"en5":   {"192.168.50.10"},
			"en12":  {"10.10.1.220"},
			"utun6": {"10.66.66.3"},
		},
		map[string]interfaceMeta{
			"en0":   {active: true, sawStatus: true, speedMbps: 0},
			"en5":   {active: true, sawStatus: true, speedMbps: 100},
			"en12":  {active: true, sawStatus: true, speedMbps: 1000},
			"utun6": {active: true, sawStatus: true, speedMbps: 0},
		},
		map[string]string{
			"en0":  "Wi-Fi",
			"en5":  "Ethernet Adapter",
			"en12": "USB 10/100/1000 LAN",
		},
	)

	if len(got) != 3 {
		t.Fatalf("effective interfaces = %#v, want 3 physical interfaces", got)
	}
	if got[0].Name != "en12" || got[1].Name != "en5" || got[2].Name != "en0" {
		t.Fatalf("interface priority = %#v, want en12 > en5 > en0", got)
	}
}

func TestTrustedPrefixMatchesAnyEffectivePhysicalInterface(t *testing.T) {
	ifaces := selectActiveInterfaces(
		map[string][]string{
			"en0":  {"10.125.171.66"},
			"en12": {"10.10.1.220"},
		},
		map[string]interfaceMeta{
			"en0":  {active: true, sawStatus: true},
			"en12": {active: true, sawStatus: true, speedMbps: 1000},
		},
		map[string]string{
			"en0":  "Wi-Fi",
			"en12": "USB 10/100/1000 LAN",
		},
	)

	if !interfacesMatchPrefix(ifaces, []string{"10.10.1."}) {
		t.Fatalf("trusted prefix should match while wired home network is still present: %#v", ifaces)
	}
}

func TestTrustedPrefixRequiresAtLeastOneEffectivePhysicalMatch(t *testing.T) {
	ifaces := selectActiveInterfaces(
		map[string][]string{
			"en0":   {"10.125.171.66"},
			"utun6": {"10.10.1.9"},
		},
		map[string]interfaceMeta{
			"en0":   {active: true, sawStatus: true},
			"utun6": {active: true, sawStatus: true},
		},
		map[string]string{
			"en0": "Wi-Fi",
		},
	)

	if interfacesMatchPrefix(ifaces, []string{"10.10.1."}) {
		t.Fatalf("trusted prefix must not match only through ignored tunnel interfaces: %#v", ifaces)
	}
}

func TestParseMediaSpeedMbps(t *testing.T) {
	tests := map[string]int{
		"media: autoselect (100baseTX <full-duplex>)": 100,
		"media: autoselect (1000baseT <full-duplex>)": 1000,
		"media: autoselect (2.5GbaseT <full-duplex>)": 2500,
		"media: autoselect (10GbaseT <full-duplex>)":  10000,
	}
	for input, want := range tests {
		if got := parseMediaSpeedMbps(input); got != want {
			t.Fatalf("parseMediaSpeedMbps(%q) = %d, want %d", input, got, want)
		}
	}
}
