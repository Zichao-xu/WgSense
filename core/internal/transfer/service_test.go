package transfer

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"

	"github.com/bethropolis/localgo/pkg/discovery"
	"github.com/bethropolis/localgo/pkg/model"
)

func TestProbeDeviceUsesV2RegisterAndPreservesHTTPS(t *testing.T) {
	var received model.RegisterDto
	peer := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/api/localsend/v2/register" {
			t.Fatalf("unexpected discovery request: %s %s", r.Method, r.URL.Path)
		}
		if err := json.NewDecoder(r.Body).Decode(&received); err != nil {
			t.Fatalf("decode register request: %v", err)
		}
		json.NewEncoder(w).Encode(model.InfoDto{
			Alias: "Official LocalSend", Version: "2.0", Fingerprint: "peer-fingerprint",
			DeviceType: model.DeviceTypeDesktop, Download: true,
		})
	}))
	defer peer.Close()

	service, err := New("WgSense-Test", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	service.httpDiscovery = discovery.NewHTTPDiscovery(nil, service.cfg.ToRegisterDto(), nil, service.logger)
	host, port := splitServerAddress(t, peer.Listener.Addr().String())
	device := service.probeDeviceInfoAtPorts(context.Background(), host, []int{port})
	if device == nil {
		t.Fatal("expected LocalSend device")
	}
	if device.Protocol != string(model.ProtocolTypeHTTPS) {
		t.Fatalf("protocol = %q, want https", device.Protocol)
	}
	if device.Alias != "Official LocalSend" || received.Alias != "WgSense-Test" {
		t.Fatalf("unexpected register exchange: peer=%q local=%q", device.Alias, received.Alias)
	}
}

func TestProbeDeviceFallsBackToHTTP(t *testing.T) {
	peer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		json.NewEncoder(w).Encode(model.InfoDto{Alias: "HTTP Peer", Version: "2.0", DeviceType: model.DeviceTypeDesktop})
	}))
	defer peer.Close()

	service, err := New("WgSense-Test", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	service.httpDiscovery = discovery.NewHTTPDiscovery(nil, service.cfg.ToRegisterDto(), nil, service.logger)
	host, port := splitServerAddress(t, peer.Listener.Addr().String())
	device := service.probeDeviceInfoAtPorts(context.Background(), host, []int{port})
	if device == nil || device.Protocol != string(model.ProtocolTypeHTTP) {
		t.Fatalf("device = %#v, want HTTP peer", device)
	}
}

func TestScannedDeviceRemainsAvailableForSendLookup(t *testing.T) {
	service, err := New("WgSense-Test", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	device := DeviceInfo{
		ID: "10.10.1.20:53317", IP: "10.10.1.20", Port: 53317,
		Alias: "Scanned Peer", Protocol: "https", Source: SourceScan,
	}
	service.cacheDevice(device)
	got, ok := service.FindDevice(device.ID)
	if !ok || got.Protocol != "https" || got.Source != SourceScan {
		t.Fatalf("cached device lost: %#v, ok=%v", got, ok)
	}
}

func TestSecurityIdentityPersistsAcrossServiceCreation(t *testing.T) {
	dir := t.TempDir()
	first, err := New("WgSense-Test", dir)
	if err != nil {
		t.Fatal(err)
	}
	second, err := New("WgSense-Test", dir)
	if err != nil {
		t.Fatal(err)
	}
	if first.cfg.SecurityContext.CertificateHash != second.cfg.SecurityContext.CertificateHash {
		t.Fatal("TLS fingerprint changed across service creation")
	}
	info, err := os.Stat(filepath.Join(dir, ".security"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Fatalf("security file mode = %o, want 600", info.Mode().Perm())
	}
}

func splitServerAddress(t *testing.T, address string) (string, int) {
	t.Helper()
	host, portString, err := net.SplitHostPort(address)
	if err != nil {
		t.Fatal(err)
	}
	port, err := strconv.Atoi(portString)
	if err != nil {
		t.Fatal(err)
	}
	return host, port
}

func TestExpiredScannedDeviceIsRemoved(t *testing.T) {
	service, err := New("WgSense-Test", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	device := DeviceInfo{ID: "10.0.0.2:53317", IP: "10.0.0.2", Port: 53317, Protocol: "https", Source: SourceScan}
	service.deviceCache[device.ID] = cachedDevice{info: device, lastSeen: time.Now().Add(-deviceCacheTTL - time.Second)}
	if _, ok := service.FindDevice(device.ID); ok {
		t.Fatal("expired scan result remained in cache")
	}
}
