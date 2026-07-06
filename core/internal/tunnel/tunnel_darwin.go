// Package tunnel 的 macOS stub 实现。
// 阶段 1 替换为真实集成：wireguard-go + NetworkExtension / scutil。
package tunnel

// stubManager 是阶段 0 的占位实现，阶段 1 替换为真实集成。
type stubManager struct{}

func (stubManager) Connect(string) error                { return nil }
func (stubManager) Disconnect(string) error             { return nil }
func (stubManager) Status(string) (State, error)        { return StateUnknown, nil }
func (stubManager) DiscoverServices() ([]string, error) { return nil, nil }

func newPlatformManager() Manager { return stubManager{} }
