// Package tunnel 的 UAPI 配置转换。
// wireguard-go 的 IpcSet 接受 UAPI 文本格式(不同于 .conf)。
// 本文件把 config.Profile 转成 UAPI 文本。
package tunnel

import (
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"strings"

	"github.com/wgsense/core/internal/config"
)

// buildUAPI 把 Profile 转成 wireguard-go 的 UAPI 配置文本。
// UAPI 格式:key=value 每行。
// 注意：空行在 wireguard-go 的 IpcSet 中表示"结束"，不能用来分段。
// public_key= 行本身会触发从 device 配置到 peer 配置的切换。
func buildUAPI(p *config.Profile) string {
	var b strings.Builder
	// Interface 段
	b.WriteString("private_key=" + base64ToHex(p.Interface.PrivateKey) + "\n")
	if p.Interface.ListenPort > 0 {
		b.WriteString(fmt.Sprintf("listen_port=%d\n", p.Interface.ListenPort))
	}
	// Peer 段（直接跟在 interface 后面，不加空行）
	for _, peer := range p.Peers {
		b.WriteString("public_key=" + base64ToHex(peer.PublicKey) + "\n")
		if peer.PresharedKey != "" {
			b.WriteString("preshared_key=" + base64ToHex(peer.PresharedKey) + "\n")
		}
		if peer.Endpoint != "" {
			b.WriteString("endpoint=" + peer.Endpoint + "\n")
		}
		for _, ip := range peer.AllowedIPs {
			b.WriteString("allowed_ip=" + ip + "\n")
		}
		if peer.PersistentKeepaliveInterval > 0 {
			b.WriteString(fmt.Sprintf("persistent_keepalive_interval=%d\n", peer.PersistentKeepaliveInterval))
		}
	}
	return b.String()
}

// base64ToHex:WG .conf 的 key 是 base64，UAPI 要 hex。
func base64ToHex(b64 string) string {
	data, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return ""
	}
	return hex.EncodeToString(data)
}
