package proxy

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestClientMatchesMihomoContracts(t *testing.T) {
	const secret = "controller-secret"
	var mu sync.Mutex
	requests := map[string]int{}
	var configPatch map[string]interface{}

	controller := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+secret {
			http.Error(w, `{"message":"Unauthorized"}`, http.StatusUnauthorized)
			return
		}
		mu.Lock()
		requests[r.Method+" "+r.URL.Path]++
		mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/version":
			io.WriteString(w, `{"meta":true,"version":"Mihomo v1"}`)
		case "/configs":
			if r.Method == http.MethodPatch {
				if err := json.NewDecoder(r.Body).Decode(&configPatch); err != nil {
					t.Errorf("decode config patch: %v", err)
				}
				io.WriteString(w, `{}`)
				return
			}
			io.WriteString(w, `{"port":7891,"socks-port":7892,"redir-port":7893,"tproxy-port":7894,"mixed-port":7890,"allow-lan":true,"bind-address":"*","mode":"rule","mode-list":["rule","global"],"modes":["rule","global","direct"],"log-level":"info","ipv6":true,"tun":{"enable":true}}`)
		case "/providers/proxies":
			io.WriteString(w, `{"providers":{"airport":{"vehicleType":"HTTP","updatedAt":"2026-07-14T12:00:00Z","testUrl":"https://example.com/204","subscriptionInfo":{"Download":10,"Upload":20,"Total":1000,"Expire":1900000000},"proxies":[{"name":"A","type":"Shadowsocks"},{"name":"B","type":"WireGuard"}]}}}`)
		case "/providers/rules":
			io.WriteString(w, `{"providers":{"ads":{"type":"Rule","behavior":"domain","format":"mrs","ruleCount":42,"updatedAt":"2026-07-14T12:00:00Z","vehicleType":"HTTP","url":"https://example.com/ads.mrs"}}}`)
		case "/group/Auto/delay":
			io.WriteString(w, `{"A":32,"B":55}`)
		case "/dns/query":
			io.WriteString(w, `{"Status":0,"Answer":[{"name":"example.com.","type":1,"TTL":60,"data":"93.184.216.34"}]}`)
		case "/cache/fakeip/flush", "/cache/dns/flush", "/configs/geo", "/restart":
			io.WriteString(w, `{}`)
		default:
			if strings.HasPrefix(r.URL.Path, "/providers/proxies/") || strings.HasPrefix(r.URL.Path, "/providers/rules/") {
				io.WriteString(w, `{}`)
				return
			}
			http.NotFound(w, r)
		}
	}))
	defer controller.Close()

	cfg := DefaultConfig()
	cfg.Address = controller.URL
	cfg.Secret = secret
	client, err := NewClient(cfg)
	if err != nil {
		t.Fatal(err)
	}

	configs, err := client.GetConfigs()
	if err != nil {
		t.Fatal(err)
	}
	if !configs.Tun.Enable || configs.TProxyPort != 7894 || !configs.AllowLan || len(configs.Modes) != 3 {
		t.Fatalf("unexpected configs: %#v", configs)
	}
	providers, err := client.GetProxyProviders()
	if err != nil {
		t.Fatal(err)
	}
	provider := providers.Providers["airport"]
	if provider.Name != "airport" || provider.ProxyCount != 2 || provider.SubscriptionInfo == nil || provider.SubscriptionInfo.Total != 1000 {
		t.Fatalf("unexpected proxy provider: %#v", provider)
	}
	if len(provider.Proxies) != 0 {
		t.Fatalf("provider response retained %d redundant proxies", len(provider.Proxies))
	}
	ruleProviders, err := client.GetRuleProviders()
	if err != nil {
		t.Fatal(err)
	}
	ruleProvider := ruleProviders.Providers["ads"]
	if ruleProvider.Name != "ads" || ruleProvider.RuleCount != 42 || ruleProvider.Format != "mrs" {
		t.Fatalf("unexpected rule provider: %#v", ruleProvider)
	}
	delays, err := client.TestGroupDelay("Auto")
	if err != nil {
		t.Fatal(err)
	}
	if delays.Delays["A"] != 32 || delays.Delays["B"] != 55 {
		t.Fatalf("unexpected group delays: %#v", delays)
	}
	if err := client.SetTUN(false); err != nil {
		t.Fatal(err)
	}
	tun, ok := configPatch["tun"].(map[string]interface{})
	if !ok || tun["enable"] != false {
		t.Fatalf("TUN patch must be nested: %#v", configPatch)
	}
	if _, err := client.DNSQuery("example.com", "A"); err != nil {
		t.Fatal(err)
	}
	for _, operation := range []func() error{
		client.FlushFakeIP,
		client.FlushDNSCache,
		client.UpdateGeoData,
		client.RestartCore,
		func() error { return client.UpdateProxyProvider("airport") },
		func() error { return client.HealthCheckProvider("airport") },
		func() error { return client.UpdateRuleProvider("ads") },
	} {
		if err := operation(); err != nil {
			t.Fatal(err)
		}
	}
	mu.Lock()
	defer mu.Unlock()
	if requests["POST /restart"] != 1 || requests["GET /providers/proxies/airport/healthcheck"] != 1 {
		t.Fatalf("expected operations were not forwarded: %#v", requests)
	}
}

func TestClientWebSocketUsesAuthenticationAndWSSchemeConversion(t *testing.T) {
	const secret = "ws-secret"
	upgrader := websocket.Upgrader{}
	controller := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/traffic" {
			http.NotFound(w, r)
			return
		}
		if r.Header.Get("Authorization") != "Bearer "+secret {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		connection, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Errorf("upgrade: %v", err)
			return
		}
		defer connection.Close()
		if err := connection.WriteJSON(map[string]int{"up": 12, "down": 34}); err != nil {
			t.Errorf("write websocket: %v", err)
		}
		<-time.After(100 * time.Millisecond)
	}))
	defer controller.Close()

	cfg := DefaultConfig()
	cfg.Address = controller.URL
	cfg.Secret = secret
	client, err := NewClient(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if got := client.websocketURL("/traffic"); !strings.HasPrefix(got, "ws://") {
		t.Fatalf("websocket URL = %q", got)
	}
	client.mu.Lock()
	client.baseURL = "https://mihomo.example"
	client.mu.Unlock()
	if got := client.websocketURL("/traffic"); got != "wss://mihomo.example/traffic" {
		t.Fatalf("secure websocket URL = %q", got)
	}
	client.mu.Lock()
	client.baseURL = controller.URL
	client.mu.Unlock()

	ctx, cancelContext := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancelContext()
	messages, cancel, err := client.SubscribeTraffic(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer cancel()
	select {
	case message := <-messages:
		if message.Error != nil {
			t.Fatal(message.Error)
		}
		if !strings.Contains(string(message.Data), `"down":34`) {
			t.Fatalf("unexpected websocket message: %s", message.Data)
		}
	case <-ctx.Done():
		t.Fatal("timed out waiting for authenticated websocket message")
	}
}

func TestRuntimeConfigPatchValidation(t *testing.T) {
	port := 65536
	if _, err := (RuntimeConfigPatch{MixedPort: &port}).values(); err == nil {
		t.Fatal("out-of-range port unexpectedly accepted")
	}
	enabled := true
	values, err := (RuntimeConfigPatch{Tun: &TunConfigPatch{Enable: &enabled}}).values()
	if err != nil {
		t.Fatal(err)
	}
	tun := values["tun"].(map[string]bool)
	if !tun["enable"] {
		t.Fatalf("unexpected nested TUN patch: %#v", values)
	}
}
