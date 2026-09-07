package policy

import (
	"errors"
	"path/filepath"
	"reflect"
	"testing"
	"time"

	"github.com/wgsense/core/internal/config"
	"github.com/wgsense/core/internal/tunnel"
)

// mock 实现，用于隔离测试策略逻辑

type mockLocation struct{ trusted bool }

func (m mockLocation) IsHome([]string) bool   { return m.trusted }
func (m mockLocation) CurrentIPv4s() []string { return nil }

type mockTunnel struct {
	state      tunnel.State
	connectErr error
}

func (m *mockTunnel) Connect(string) error {
	if m.connectErr != nil {
		return m.connectErr
	}
	m.state = tunnel.StateConnected
	return nil
}
func (m *mockTunnel) Disconnect(string) error                   { m.state = tunnel.StateDisconnected; return nil }
func (m *mockTunnel) Status(string) (tunnel.State, error)       { return m.state, nil }
func (m *mockTunnel) DiscoverServices() ([]string, error)       { return nil, nil }
func (m *mockTunnel) ConfigDir() string                         { return "/tmp/mock" }
func (m *mockTunnel) SaveProfile(string, string) error          { return nil }
func (m *mockTunnel) LoadProfileContent(string) (string, error) { return "", nil }
func (m *mockTunnel) DeleteProfile(string) error                { return nil }
func (m *mockTunnel) InterfaceBytes(string) (uint64, uint64)    { return 0, 0 }

type countingTunnel struct {
	mockTunnel
	connects int
}

func (m *countingTunnel) Connect(service string) error {
	m.connects++
	return m.mockTunnel.Connect(service)
}

type blockingTunnel struct {
	mockTunnel
	started chan struct{}
	release chan struct{}
}

func (m *blockingTunnel) Connect(string) error {
	close(m.started)
	<-m.release
	m.state = tunnel.StateConnected
	return nil
}

type mockHealth struct{ connected bool }

func (m mockHealth) CheckConnectivity() bool       { return m.connected }
func (m mockHealth) IsStaleConnected(tc bool) bool { return tc && !m.connected }

type mutableHealth struct{ connected bool }

func (m *mutableHealth) CheckConnectivity() bool       { return m.connected }
func (m *mutableHealth) IsStaleConnected(tc bool) bool { return tc && !m.connected }

type mockPause struct{ paused bool }

func (m *mockPause) Pause() error   { m.paused = true; return nil }
func (m *mockPause) Resume() error  { m.paused = false; return nil }
func (m *mockPause) IsPaused() bool { return m.paused }

func TestRunOnceTrustedNetworkDisconnects(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateConnected}
	cfg := config.Default()
	cfg.DesiredGuardEnabled = true
	eng := New(cfg, mockLocation{trusted: true}, tun, mockHealth{connected: true}, &mockPause{})
	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	if tun.state != tunnel.StateDisconnected {
		t.Errorf("受信任网络应断开, 实际 %s", tun.state)
	}
}

func TestRunOnceUntrustedConnectsWhenEnabled(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateDisconnected}
	cfg := config.Default()
	cfg.AutoConnectUntrusted = true
	eng := New(cfg, mockLocation{trusted: false}, tun, mockHealth{}, &mockPause{})
	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	if tun.state != tunnel.StateConnected {
		t.Errorf("非受信任网络应连接, 实际 %s", tun.state)
	}
}

func TestResumeImmediatelyAppliesUntrustedPolicy(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateDisconnected}
	pause := &mockPause{paused: true}
	cfg := config.Default()
	cfg.AutoConnectUntrusted = true
	eng := New(cfg, mockLocation{trusted: false}, tun, mockHealth{}, pause)

	if err := eng.Resume(); err != nil {
		t.Fatal(err)
	}
	if pause.paused {
		t.Fatal("恢复守护后仍处于暂停状态")
	}
	if tun.state != tunnel.StateConnected {
		t.Fatalf("恢复守护后应立即连接非受信任网络, 实际 %s", tun.state)
	}
}

func TestResumeImmediatelyDisconnectsTrustedNetwork(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateConnected}
	pause := &mockPause{paused: true}
	cfg := config.Default()
	cfg.AutoConnectUntrusted = true
	eng := New(cfg, mockLocation{trusted: true}, tun, mockHealth{connected: true}, pause)

	if err := eng.Resume(); err != nil {
		t.Fatal(err)
	}
	if tun.state != tunnel.StateDisconnected {
		t.Fatalf("恢复守护后应立即断开受信任网络, 实际 %s", tun.state)
	}
}

func TestRunOnceUntrustedDoesNotConnectWhenAutoDisabled(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateDisconnected}
	eng := New(config.Default(), mockLocation{trusted: false}, tun, mockHealth{}, &mockPause{})
	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	if tun.state != tunnel.StateDisconnected {
		t.Errorf("默认不应自动连接, 实际 %s", tun.state)
	}
	if !eng.Status().Auto {
		return
	}
	t.Fatal("默认配置不应启用非受信任网络自动连接")
}

func TestPassiveEngineRejectsManualConnect(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateDisconnected}
	eng := New(config.Default(), mockLocation{trusted: false}, tun, mockHealth{}, &mockPause{})
	eng.SetPassive(true)
	if err := eng.Connect(); err == nil {
		t.Fatal("passive engine must reject WireGuard connect")
	}
	if tun.state != tunnel.StateDisconnected {
		t.Fatalf("passive connect changed tunnel state to %s", tun.state)
	}
	if !eng.Status().Passive {
		t.Fatal("passive mode is missing from status")
	}
	if !eng.Status().DesiredVPNEnabled {
		t.Fatal("连接失败也应保留用户开启 VPN 的意图")
	}
}

func TestManualConnectFailureKeepsDesiredVPNOn(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateDisconnected, connectErr: errors.New("network blocked")}
	eng := New(config.Default(), mockLocation{trusted: false}, tun, mockHealth{}, &mockPause{})

	if err := eng.Connect(); err == nil {
		t.Fatal("connect should fail")
	}
	status := eng.Status()
	if !status.DesiredVPNEnabled {
		t.Fatalf("连接失败后不应清空 VPN 意图: %#v", status)
	}
	if status.State != string(tunnel.StateDisconnected) {
		t.Fatalf("真实隧道状态仍应是断开: %#v", status)
	}
}

func TestGuardIntentDrivesStatusWithoutConnectedTunnel(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateDisconnected}
	cfg := config.Default()
	cfg.DesiredGuardEnabled = true
	cfg.AutoConnectUntrusted = true
	eng := New(cfg, mockLocation{trusted: false}, tun, mockHealth{}, &mockPause{})

	status := eng.Status()
	if !status.DesiredGuardEnabled || !status.DesiredVPNEnabled {
		t.Fatalf("非受信网络下守护意图应显示保持 VPN: %#v", status)
	}
	if status.State != string(tunnel.StateDisconnected) {
		t.Fatalf("意图不应伪造真实连接状态: %#v", status)
	}
}

func TestRunOnceUntrustedPaused(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateDisconnected}
	eng := New(config.Default(), mockLocation{trusted: false}, tun, mockHealth{}, &mockPause{paused: true})
	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	if tun.state != tunnel.StateDisconnected {
		t.Error("暂停时不应连接")
	}
}

func TestRunOnceStaleConnected(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateConnected}
	// 单次波动不能破坏长连接；连续多次失败才重启。
	cfg := config.Default()
	cfg.DesiredVPNEnabled = true
	eng := New(cfg, mockLocation{trusted: false}, tun, mockHealth{connected: false}, &mockPause{})
	for i := 0; i < maxHealthFailures-1; i++ {
		eng.lastHealthCheck = time.Time{}
		if err := eng.RunOnce(); err != nil {
			t.Fatal(err)
		}
		if tun.state != tunnel.StateConnected || eng.healthFailures != i+1 {
			t.Fatalf("failure %d restarted too early: state=%s failures=%d", i+1, tun.state, eng.healthFailures)
		}
	}
	eng.lastHealthCheck = time.Time{}
	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	if tun.state != tunnel.StateConnected {
		t.Errorf("假连接重启后应 Connected, 实际 %s", tun.state)
	}
	if eng.healthFailures != 0 || eng.lastAutoUp.IsZero() {
		t.Fatalf("重启后健康状态未复位: failures=%d lastAutoUp=%v", eng.healthFailures, eng.lastAutoUp)
	}
}

func TestManualConnectStartsHealthGrace(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateDisconnected}
	eng := New(config.Default(), mockLocation{trusted: false}, tun, mockHealth{connected: false}, &mockPause{})

	if err := eng.Connect(); err != nil {
		t.Fatal(err)
	}
	if eng.lastAutoUp.IsZero() || eng.healthFailures != 0 {
		t.Fatalf("手动连接后未进入宽限期: lastAutoUp=%v failures=%d", eng.lastAutoUp, eng.healthFailures)
	}
	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	if eng.healthFailures != 0 {
		t.Fatalf("宽限期内不应立刻做假连接判定: failures=%d", eng.healthFailures)
	}
}

func TestManualConnectDoesNotRestartExistingTunnel(t *testing.T) {
	tun := &countingTunnel{mockTunnel: mockTunnel{state: tunnel.StateConnected}}
	eng := New(config.Default(), mockLocation{trusted: false}, tun, mockHealth{connected: true}, &mockPause{})

	if err := eng.Connect(); err != nil {
		t.Fatal(err)
	}
	if tun.connects != 0 {
		t.Fatalf("already-connected tunnel should not be reconnected: %d", tun.connects)
	}
}

func TestRunOnceSkipsWhileConnectInProgress(t *testing.T) {
	tun := &blockingTunnel{
		mockTunnel: mockTunnel{state: tunnel.StateDisconnected},
		started:    make(chan struct{}),
		release:    make(chan struct{}),
	}
	cfg := config.Default()
	cfg.AutoConnectUntrusted = true
	eng := New(cfg, mockLocation{trusted: false}, tun, mockHealth{}, &mockPause{})

	done := make(chan error, 1)
	go func() { done <- eng.RunOnce() }()
	<-tun.started

	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	close(tun.release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if tun.state != tunnel.StateConnected {
		t.Fatalf("first connect should finish: %s", tun.state)
	}
}

func TestShutdownCleanupPreservesDesiredVPNIntent(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateConnected}
	cfg := config.Default()
	cfg.DesiredVPNEnabled = true
	eng := New(cfg, mockLocation{trusted: false}, tun, mockHealth{connected: true}, &mockPause{})
	path := filepath.Join(t.TempDir(), "settings.json")
	eng.SetConfigPath(path)

	if err := eng.ShutdownCleanup(); err != nil {
		t.Fatal(err)
	}
	if tun.state != tunnel.StateDisconnected {
		t.Fatalf("shutdown cleanup should disconnect the tunnel: %s", tun.state)
	}
	if !eng.Status().DesiredVPNEnabled {
		t.Fatal("daemon shutdown cleanup must not clear the user's VPN intent")
	}
	if _, err := config.LoadRuntime(path); !config.IsNotExist(err) {
		t.Fatalf("shutdown cleanup should not rewrite runtime config, err=%v", err)
	}
}

func TestUpdateConfigPersistsRuntimeConfig(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateDisconnected}
	eng := New(config.Default(), mockLocation{trusted: false}, tun, mockHealth{}, &mockPause{})
	path := filepath.Join(t.TempDir(), "settings.json")
	eng.SetConfigPath(path)

	cfg := config.Default()
	cfg.AutoConnectUntrusted = true
	cfg.TrustedNetworkPrefixes = []string{"10.10.1."}
	cfg.HealthCheckIntervalSeconds = 17
	if err := eng.UpdateConfig(cfg); err != nil {
		t.Fatal(err)
	}
	got, err := config.LoadRuntime(path)
	if err != nil {
		t.Fatal(err)
	}
	if !got.AutoConnectUntrusted || !reflect.DeepEqual(got.TrustedNetworkPrefixes, []string{"10.10.1."}) {
		t.Fatalf("persisted config mismatch: %#v", got)
	}
	if got.HealthCheckIntervalSeconds != 17 {
		t.Fatalf("health interval not persisted: %d", got.HealthCheckIntervalSeconds)
	}
}

func TestHealthRestartFailureKeepsRetrySoon(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateConnected, connectErr: errors.New("temporary network down")}
	cfg := config.Default()
	cfg.DesiredVPNEnabled = true
	eng := New(cfg, mockLocation{trusted: false}, tun, mockHealth{connected: false}, &mockPause{})

	for i := 0; i < maxHealthFailures; i++ {
		eng.lastHealthCheck = time.Time{}
		_ = eng.RunOnce()
	}
	if eng.autoFailures != 1 {
		t.Fatalf("健康重启失败后应计入自动重试: %d", eng.autoFailures)
	}
	if eng.nextAutoAttempt.IsZero() || time.Until(eng.nextAutoAttempt) > 11*time.Second {
		t.Fatalf("首次失败退避不应太久: %v", eng.nextAutoAttempt)
	}
}

func TestRunOnceTransientHealthFailureRecovers(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateConnected}
	health := &mutableHealth{connected: false}
	cfg := config.Default()
	cfg.DesiredVPNEnabled = true
	eng := New(cfg, mockLocation{trusted: false}, tun, health, &mockPause{})
	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	health.connected = true
	eng.lastHealthCheck = time.Time{}
	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	if eng.healthFailures != 0 || !eng.lastAutoUp.IsZero() {
		t.Fatalf("transient failure should recover without reconnect: %#v", eng)
	}
}

func TestRunOnceUntrustedConnectedHealthy(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateConnected}
	// health 报告通 → 正常，不动
	cfg := config.Default()
	cfg.DesiredVPNEnabled = true
	eng := New(cfg, mockLocation{trusted: false}, tun, mockHealth{connected: true}, &mockPause{})
	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	if tun.state != tunnel.StateConnected {
		t.Error("健康连接不应被干扰")
	}
}
