// Package location 提供网络位置感知：检测当前是否命中受信任网络前缀。
// 智能管理的基础：受信任网络断开 WG，非受信任网络按策略自动连接。
package location

import "net"

// Locator 检测网络位置。
type Locator interface {
	// IsHome 返回当前是否命中任一受信任前缀(如 "10.0.0.")。
	IsHome(prefixes []string) bool
	// CurrentIPv4s 返回当前所有非环回 IPv4。
	CurrentIPv4s() []string
}

type defaultLocator struct{}

// New 创建默认 Locator。
func New() Locator { return defaultLocator{} }

func (defaultLocator) CurrentIPv4s() []string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	var ips []string
	for _, iface := range ifaces {
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			if ipnet, ok := addr.(*net.IPNet); ok && !ipnet.IP.IsLoopback() {
				if ip4 := ipnet.IP.To4(); ip4 != nil {
					ips = append(ips, ip4.String())
				}
			}
		}
	}
	return ips
}

func (l defaultLocator) IsHome(prefixes []string) bool {
	for _, ip := range l.CurrentIPv4s() {
		for _, p := range prefixes {
			if len(ip) >= len(p) && ip[:len(p)] == p {
				return true
			}
		}
	}
	return false
}
