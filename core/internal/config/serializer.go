// Package config 的 .conf 序列化器。
// 将 Profile 写回标准 WireGuard .conf 格式。
package config

import (
	"fmt"
	"strings"
)

// Serialize 将 Profile 序列化为 .conf 文本。
func Serialize(p *Profile) string {
	var b strings.Builder

	b.WriteString("[Interface]\n")
	if p.Interface.PrivateKey != "" {
		b.WriteString("PrivateKey = " + p.Interface.PrivateKey + "\n")
	}
	if p.Interface.Address != "" {
		b.WriteString("Address = " + p.Interface.Address + "\n")
	}
	if p.Interface.DNS != "" {
		b.WriteString("DNS = " + p.Interface.DNS + "\n")
	}
	if p.Interface.ListenPort > 0 {
		b.WriteString(fmt.Sprintf("ListenPort = %d\n", p.Interface.ListenPort))
	}
	if p.Interface.MTU > 0 && p.Interface.MTU != 1420 {
		b.WriteString(fmt.Sprintf("MTU = %d\n", p.Interface.MTU))
	}

	for _, peer := range p.Peers {
		b.WriteString("\n[Peer]\n")
		if peer.PublicKey != "" {
			b.WriteString("PublicKey = " + peer.PublicKey + "\n")
		}
		if peer.PresharedKey != "" {
			b.WriteString("PresharedKey = " + peer.PresharedKey + "\n")
		}
		if peer.Endpoint != "" {
			b.WriteString("Endpoint = " + peer.Endpoint + "\n")
		}
		if len(peer.AllowedIPs) > 0 {
			b.WriteString("AllowedIPs = " + strings.Join(peer.AllowedIPs, ", ") + "\n")
		}
		if peer.PersistentKeepaliveInterval > 0 {
			b.WriteString(fmt.Sprintf("PersistentKeepalive = %d\n", peer.PersistentKeepaliveInterval))
		}
	}

	return b.String()
}
