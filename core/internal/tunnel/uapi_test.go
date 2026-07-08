package tunnel

import (
	"strings"
	"testing"

	"github.com/wgsense/core/internal/config"
)

func TestBuildUAPI(t *testing.T) {
	profile := &config.Profile{
		Interface: config.InterfaceConfig{
			PrivateKey:  "yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=",
			ListenPort: 51820,
			MTU:         1420,
		},
		Peers: []config.PeerConfig{
			{
				PublicKey:                   "xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=",
				Endpoint:                    "192.168.1.1:51820",
				AllowedIPs:                  []string{"0.0.0.0/0"},
				PersistentKeepaliveInterval: 25,
			},
		},
	}

	uapi := buildUAPI(profile)

	if !strings.Contains(uapi, "private_key=") {
		t.Error("缺少 private_key")
	}
	if !strings.Contains(uapi, "listen_port=51820") {
		t.Error("缺少 listen_port")
	}
	if !strings.Contains(uapi, "public_key=") {
		t.Error("缺少 public_key")
	}
	if !strings.Contains(uapi, "endpoint=192.168.1.1:51820") {
		t.Error("缺少 endpoint")
	}
	if !strings.Contains(uapi, "allowed_ip=0.0.0.0/0") {
		t.Error("缺少 allowed_ip")
	}
	if !strings.Contains(uapi, "persistent_keepalive_interval=25") {
		t.Error("缺少 keepalive")
	}
	// private_key 应是 hex(64 字符),不是 base64
	for _, line := range strings.Split(uapi, "\n") {
		if strings.HasPrefix(line, "private_key=") {
			hex := strings.TrimPrefix(line, "private_key=")
			if len(hex) != 64 {
				t.Errorf("private_key hex 长度 %d, 期望 64", len(hex))
			}
		}
	}
}

func TestBase64ToHex(t *testing.T) {
	b64 := "yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk="
	h := base64ToHex(b64)
	if len(h) != 64 {
		t.Errorf("hex 长度 %d, 期望 64", len(h))
	}
	// 同一 key 转两次应一致
	if base64ToHex(b64) != h {
		t.Error("base64ToHex 不稳定")
	}
}

func TestParseCIDR(t *testing.T) {
	ip, mask, err := parseCIDR("10.0.0.2/24")
	if err != nil {
		t.Fatal(err)
	}
	if ip != "10.0.0.2" || mask != "24" {
		t.Errorf("期望 10.0.0.2/24, 实际 %s/%s", ip, mask)
	}

	if _, _, err := parseCIDR("invalid"); err == nil {
		t.Error("无效 CIDR 应报错")
	}
}
