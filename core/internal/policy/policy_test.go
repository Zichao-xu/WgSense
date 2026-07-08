package policy

import (
	"testing"

	"github.com/wgsense/core/internal/config"
	"github.com/wgsense/core/internal/tunnel"
)

// mock 实现，用于隔离测试策略逻辑

type mockLocation struct{ home bool }

func (m mockLocation) IsHome([]string) bool      { return m.home }
func (m mockLocation) CurrentIPv4s() []string     { return nil }

type mockTunnel struct{ state tunnel.State }

func (m *mockTunnel) Connect(string) error                { m.state = tunnel.StateConnected; return nil }
func (m *mockTunnel) Disconnect(string) error             { m.state = tunnel.StateDisconnected; return nil }
func (m *mockTunnel) Status(string) (tunnel.State, error) { return m.state, nil }
func (m *mockTunnel) DiscoverServices() ([]string, error) { return nil, nil }
func (m *mockTunnel) ConfigDir() string                   { return "/tmp/mock" }
func (m *mockTunnel) SaveProfile(string, string) error    { return nil }
func (m *mockTunnel) LoadProfileContent(string) (string, error) { return "", nil }
func (m *mockTunnel) DeleteProfile(string) error          { return nil }

type mockHealth struct{ connected bool }

func (m mockHealth) CheckConnectivity() bool              { return m.connected }
func (m mockHealth) IsStaleConnected(tc bool) bool        { return tc && !m.connected }

type mockPause struct{ paused bool }

func (m *mockPause) Pause() error  { m.paused = true; return nil }
func (m *mockPause) Resume() error { m.paused = false; return nil }
func (m *mockPause) IsPaused() bool { return m.paused }

func TestRunOnceAtHome(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateConnected}
	eng := New(config.Default(), mockLocation{home: true}, tun, mockHealth{connected: true}, &mockPause{})
	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	if tun.state != tunnel.StateDisconnected {
		t.Errorf("在家应断开, 实际 %s", tun.state)
	}
}

func TestRunOnceAwayConnect(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateDisconnected}
	eng := New(config.Default(), mockLocation{home: false}, tun, mockHealth{}, &mockPause{})
	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	if tun.state != tunnel.StateConnected {
		t.Errorf("不在家应连接, 实际 %s", tun.state)
	}
}

func TestRunOnceAwayPaused(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateDisconnected}
	eng := New(config.Default(), mockLocation{home: false}, tun, mockHealth{}, &mockPause{paused: true})
	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	if tun.state != tunnel.StateDisconnected {
		t.Error("暂停时不应连接")
	}
}

func TestRunOnceStaleConnected(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateConnected}
	// health 报告不通 → 假连接
	eng := New(config.Default(), mockLocation{home: false}, tun, mockHealth{connected: false}, &mockPause{})
	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	// 应该先断开再连接，最终 Connected
	if tun.state != tunnel.StateConnected {
		t.Errorf("假连接重启后应 Connected, 实际 %s", tun.state)
	}
}

func TestRunOnceAwayConnectedHealthy(t *testing.T) {
	tun := &mockTunnel{state: tunnel.StateConnected}
	// health 报告通 → 正常，不动
	eng := New(config.Default(), mockLocation{home: false}, tun, mockHealth{connected: true}, &mockPause{})
	if err := eng.RunOnce(); err != nil {
		t.Fatal(err)
	}
	if tun.state != tunnel.StateConnected {
		t.Error("健康连接不应被干扰")
	}
}
