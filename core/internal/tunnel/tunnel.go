// Package tunnel 封装 WireGuard 隧道管理。
// 桌面端通过 wireguard-go + 系统 VPN 框架实现；移动端通过 gomobile 绑定。
package tunnel

// State 是隧道状态。
type State string

const (
	StateConnected    State = "Connected"
	StateDisconnected State = "Disconnected"
	StateConnecting   State = "Connecting"
	StateUnknown      State = "Unknown"
)

// Manager 管理 WireGuard 隧道。
type Manager interface {
	// Connect 连接指定隧道。
	Connect(service string) error
	// Disconnect 断开指定隧道。
	Disconnect(service string) error
	// Status 查询隧道状态。
	Status(service string) (State, error)
	// DiscoverServices 发现系统中的 WG 隧道名列表。
	DiscoverServices() ([]string, error)
}

// New 返回当前平台的 Manager。configDir 是 .conf 配置文件目录。
func New(configDir string) Manager {
	return newPlatformManager(configDir)
}
