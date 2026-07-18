package proxy

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNormalizeControllerURL(t *testing.T) {
	tests := map[string]string{
		"10.10.1.1:9090":              "http://10.10.1.1:9090",
		"https://mihomo.example/api/": "https://mihomo.example/api",
		" http://127.0.0.1:9090 ":     "http://127.0.0.1:9090",
	}
	for input, expected := range tests {
		actual, err := normalizeControllerURL(input)
		if err != nil {
			t.Fatalf("normalize %q: %v", input, err)
		}
		if actual != expected {
			t.Fatalf("normalize %q = %q, want %q", input, actual, expected)
		}
	}
	for _, input := range []string{"", "ftp://router:21", "http://user:pass@router:9090", "http://router:9090?secret=x"} {
		if _, err := normalizeControllerURL(input); err == nil {
			t.Fatalf("normalize %q unexpectedly succeeded", input)
		}
	}
}

func TestServiceSettingsPersistSecretAndTrackAuthentication(t *testing.T) {
	const expectedSecret = "test-controller-secret"
	controller := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/version" {
			http.NotFound(w, r)
			return
		}
		if r.Header.Get("Authorization") != "Bearer "+expectedSecret {
			w.WriteHeader(http.StatusUnauthorized)
			json.NewEncoder(w).Encode(map[string]string{"message": "Unauthorized"})
			return
		}
		json.NewEncoder(w).Encode(map[string]interface{}{"meta": true, "version": "test"})
	}))
	defer controller.Close()

	configPath := filepath.Join(t.TempDir(), "proxy.json")
	cfg := DefaultConfig()
	cfg.Address = controller.URL
	service, err := NewPersistent(cfg, configPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := service.Start(); err != nil {
		t.Fatal(err)
	}
	status := service.Status()
	if !status.Running || status.Connected || !strings.Contains(status.LastError, "401") {
		t.Fatalf("unauthorized status was not retained: %#v", status)
	}

	status, err = service.ApplySettings(SettingsPatch{Secret: pointer(expectedSecret)})
	if err != nil {
		t.Fatal(err)
	}
	if !status.Running || !status.Connected || status.LastError != "" {
		t.Fatalf("authenticated status is incorrect: %#v", status)
	}
	settings := service.Settings()
	if !settings.SecretSet || settings.Address != controller.URL {
		t.Fatalf("public settings are incorrect: %#v", settings)
	}
	data, err := os.ReadFile(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(data), expectedSecret) {
		t.Fatal("persisted config did not contain the controller secret")
	}
	info, err := os.Stat(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Fatalf("config mode = %o, want 600", info.Mode().Perm())
	}
	loaded, err := LoadConfig(configPath)
	if err != nil {
		t.Fatal(err)
	}
	if loaded.Secret != expectedSecret || loaded.Address != controller.URL {
		t.Fatalf("loaded config differs: %#v", loaded)
	}
}

func TestSettingsHandlerNeverReturnsSecret(t *testing.T) {
	cfg := DefaultConfig()
	cfg.Secret = "must-not-leak"
	service, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/api/proxy/settings", nil)
	SettingsHandler(service).ServeHTTP(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d", recorder.Code)
	}
	if strings.Contains(recorder.Body.String(), cfg.Secret) {
		t.Fatalf("settings response leaked secret: %s", recorder.Body.String())
	}
	if !strings.Contains(recorder.Body.String(), `"secret_set":true`) {
		t.Fatalf("settings response omitted secret presence: %s", recorder.Body.String())
	}
}

func pointer[T any](value T) *T {
	return &value
}
