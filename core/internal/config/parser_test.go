package config

import (
	"os"
	"strings"
	"testing"
)

func TestParse(t *testing.T) {
	conf := `[Interface]
PrivateKey = yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=
Address = 10.0.0.2/24
DNS = 1.1.1.1
MTU = 1420

[Peer]
PublicKey = xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=
Endpoint = 192.168.1.1:51820
AllowedIPs = 0.0.0.0/0, 10.0.0.0/8
PersistentKeepalive = 25
`
	tmp, err := os.CreateTemp("", "test-*.conf")
	if err != nil {
		t.Fatal(err)
	}
	defer os.Remove(tmp.Name())
	tmp.WriteString(conf)
	tmp.Close()

	p, err := ParseFile(tmp.Name())
	if err != nil {
		t.Fatal(err)
	}

	// Interface
	if p.Interface.PrivateKey != "yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=" {
		t.Errorf("PrivateKey 不匹配: %s", p.Interface.PrivateKey)
	}
	if p.Interface.Address != "10.0.0.2/24" {
		t.Errorf("Address 不匹配: %s", p.Interface.Address)
	}
	if p.Interface.DNS != "1.1.1.1" {
		t.Errorf("DNS 不匹配: %s", p.Interface.DNS)
	}
	if p.Interface.MTU != 1420 {
		t.Errorf("MTU 不匹配: %d", p.Interface.MTU)
	}

	// Peer
	if len(p.Peers) != 1 {
		t.Fatalf("期望 1 个 peer, 实际 %d", len(p.Peers))
	}
	peer := p.Peers[0]
	if peer.PublicKey != "xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=" {
		t.Errorf("PublicKey 不匹配: %s", peer.PublicKey)
	}
	if peer.Endpoint != "192.168.1.1:51820" {
		t.Errorf("Endpoint 不匹配: %s", peer.Endpoint)
	}
	if len(peer.AllowedIPs) != 2 {
		t.Errorf("AllowedIPs 数量 %d, 期望 2", len(peer.AllowedIPs))
	}
	if peer.AllowedIPs[0] != "0.0.0.0/0" || peer.AllowedIPs[1] != "10.0.0.0/8" {
		t.Errorf("AllowedIPs 不匹配: %v", peer.AllowedIPs)
	}
	if peer.PersistentKeepaliveInterval != 25 {
		t.Errorf("Keepalive 不匹配: %d", peer.PersistentKeepaliveInterval)
	}
}

func TestParseDefaultMTU(t *testing.T) {
	conf := `[Interface]
PrivateKey = AAAA
`
	p, err := Parse(strings.NewReader(conf), "test")
	if err != nil {
		t.Fatal(err)
	}
	if p.Interface.MTU != 1420 {
		t.Errorf("默认 MTU 应为 1420, 实际 %d", p.Interface.MTU)
	}
}
