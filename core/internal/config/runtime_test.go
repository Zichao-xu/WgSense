package config

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestRuntimeConfigRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	cfg := Default()
	cfg.AutoConnectUntrusted = true
	cfg.TrustedNetworkPrefixes = []string{"10.10.1.", "192.168.1."}
	cfg.IntervalSeconds = 7
	cfg.AutoUpGraceSeconds = 45
	cfg.HealthCheckTarget = "https://www.gstatic.com/generate_204"
	cfg.HealthCheckIntervalSeconds = 11

	if err := SaveRuntime(path, cfg); err != nil {
		t.Fatal(err)
	}
	got, err := LoadRuntime(path)
	if err != nil {
		t.Fatal(err)
	}
	if got.AutoConnectUntrusted != true {
		t.Fatal("auto-connect setting was not persisted")
	}
	if !reflect.DeepEqual(got.TrustedNetworkPrefixes, cfg.TrustedNetworkPrefixes) {
		t.Fatalf("trusted prefixes = %#v", got.TrustedNetworkPrefixes)
	}
	if !reflect.DeepEqual(got.HomeNetworkPrefixes, cfg.TrustedNetworkPrefixes) {
		t.Fatalf("compat prefixes = %#v", got.HomeNetworkPrefixes)
	}
	if got.IntervalSeconds != 7 || got.AutoUpGraceSeconds != 45 || got.HealthCheckIntervalSeconds != 11 {
		t.Fatalf("timing settings were not persisted: %#v", got)
	}
}

func TestRuntimeConfigLoadLegacyHomePrefixes(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	if err := os.WriteFile(path, []byte(`{"auto_connect_away":true,"home_network_prefixes":["10.10.1."]}`), 0600); err != nil {
		t.Fatal(err)
	}

	got, err := LoadRuntime(path)
	if err != nil {
		t.Fatal(err)
	}
	if !got.AutoConnectUntrusted || !got.AutoConnectAway {
		t.Fatalf("legacy auto-connect flag was not normalized: %#v", got)
	}
	if !reflect.DeepEqual(got.TrustedNetworkPrefixes, []string{"10.10.1."}) {
		t.Fatalf("legacy home prefixes were not migrated: %#v", got.TrustedNetworkPrefixes)
	}
	if got.HealthCheckTarget == "" || got.IntervalSeconds == 0 {
		t.Fatalf("defaults were not filled: %#v", got)
	}
}
