// Package config 的 .conf 解析器。
// 解析标准 WireGuard 配置文件格式(INI 风格，[Interface] + [Peer] 段)。
package config

import (
	"bufio"
	"io"
	"os"
	"strconv"
	"strings"
)

// ParseFile 从 .conf 文件路径解析 Profile。
func ParseFile(path string) (*Profile, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	name := strings.TrimSuffix(filepathBase(path), ".conf")
	return Parse(f, name)
}

// Parse 从 reader 解析 Profile。name 用于标识。
func Parse(r io.Reader, name string) (*Profile, error) {
	p := &Profile{Name: name, Interface: InterfaceConfig{MTU: 1420}}
	scanner := bufio.NewScanner(r)
	section := ""
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || line[0] == '#' || line[0] == ';' {
			continue
		}
		if line[0] == '[' && line[len(line)-1] == ']' {
			section = strings.ToLower(strings.Trim(line, "[]"))
			if section == "peer" {
				p.Peers = append(p.Peers, PeerConfig{})
			}
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			continue
		}
		key := strings.ToLower(strings.TrimSpace(parts[0]))
		val := strings.TrimSpace(parts[1])
		switch section {
		case "interface":
			applyInterface(&p.Interface, key, val)
		case "peer":
			if len(p.Peers) == 0 {
				p.Peers = append(p.Peers, PeerConfig{})
			}
			applyPeer(&p.Peers[len(p.Peers)-1], key, val)
		}
	}
	return p, scanner.Err()
}

func applyInterface(i *InterfaceConfig, key, val string) {
	switch key {
	case "privatekey":
		i.PrivateKey = val
	case "address":
		i.Address = val
	case "dns":
		i.DNS = val
	case "listenport":
		i.ListenPort, _ = strconv.Atoi(val)
	case "mtu":
		if n, err := strconv.Atoi(val); err == nil && n > 0 {
			i.MTU = n
		}
	}
}

func applyPeer(p *PeerConfig, key, val string) {
	switch key {
	case "publickey":
		p.PublicKey = val
	case "presharedkey":
		p.PresharedKey = val
	case "endpoint":
		p.Endpoint = val
	case "allowedips":
		for _, ip := range strings.Split(val, ",") {
			ip = strings.TrimSpace(ip)
			if ip != "" {
				p.AllowedIPs = append(p.AllowedIPs, ip)
			}
		}
	case "persistentkeepalive":
		p.PersistentKeepaliveInterval, _ = strconv.Atoi(val)
	}
}

// filepathBase 避免引入 path/filepath 仅用一次。
func filepathBase(p string) string {
	for i := len(p) - 1; i >= 0; i-- {
		if p[i] == '/' || p[i] == '\\' {
			return p[i+1:]
		}
	}
	return p
}
