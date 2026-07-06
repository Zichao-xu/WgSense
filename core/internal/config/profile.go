// Package config 的 Profile 类型:对应一个 WireGuard .conf 配置。
package config

// Profile 是一个 WireGuard 配置(对应一个 .conf 文件)。
type Profile struct {
	Name      string          // profile 名(通常文件名去扩展)
	Interface InterfaceConfig
	Peers     []PeerConfig
}

// InterfaceConfig 对应 .conf 的 [Interface] 段。
type InterfaceConfig struct {
	PrivateKey string // base64
	Address    string // CIDR，如 10.0.0.2/24
	DNS        string // 可选
	ListenPort int    // 可选
	MTU        int    // 默认 1420
}

// PeerConfig 对应 .conf 的 [Peer] 段。
type PeerConfig struct {
	PublicKey                   string   // base64
	PresharedKey                string   // 可选 base64
	Endpoint                    string   // host:port
	AllowedIPs                  []string // CIDR 列表
	PersistentKeepaliveInterval int      // 秒，可选
}
