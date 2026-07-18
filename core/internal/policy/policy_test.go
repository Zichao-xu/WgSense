package policy

import (
	"testing"
	"time"

	"github.com/wgsense/core/internal/config"
	"github.com/wgsense/core/internal/tunnel"
)

// mock 实现，用于隔离测试策略逻辑

type mockLocation struct{ trusted bool }

func (m mockLocation) IsHome([]string) bool   { return m.trusted }
func (m mockLocation) CurrentIPv4s() []string { return nil }

type mockTunnel struct{ state tunnel.State }

func (m *mockTunnel) Connect(string) error                      { m.state = tunnel.StateConnected; return nil }
func (m *mockTunnel) Disconnect(string) error                   { m.state = tunnel.StateDisconnected; return nil }
func (m *mockTunnel) Status(string) (tunnel.State, error)       { return m.state, nil }
func (m *mockTunnel) DiscoverServices() ([]string, error)       { return nil, nil }
func (m *mockTunnel) ConfigDir() string                         { return "/tmp/mock" }
func (m *mockTunnel) SaveProfile(string, string) error          { return nil }
func (m *mockTunnel) LoadProfileContent(string) (string, error) { return "", nil }
func (m *mockTunnel) DeleteProfile(string) error                { return nil }
func (m *mockTunnel) InterfaceBytes(string) (uint64, uint64)    { return 0, 0 }

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
	eng := New(config.Default(), mockLocation{trusted: true}, tun, mockHealth{connected: true}, &mockPause{})
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
	// 单次波动不能破坏长连接；连续三次失败才重启。
	eng := New(config.Default(), mockLocation{trusted: false}, tun, mockHealth{connected: false}, &mockPause{})
	for i := 0; i < 2; i++ {
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

func TestRunOnceTransientHealthFailureRecovers(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateConnected}
	health := &mutableHealth{connected: false}
	eng := New(config.Default(), mockLocation{trusted: false}, tun, health, &mockPause{})
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
	eng := New(config.Default(), mockLocation{trusted: false}, tun, mockHealth{connected: true}, &mockPause{})
	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	if tun.state != tunnel.StateConnected {
		t.Error("健康连接不应被干扰")
	}
}
