// Package netstate builds a lightweight fingerprint of the current network.
package netstate

import (
	"bufio"
	"bytes"
	"net"
	"os"
	"os/exec"
	"sort"
	"strings"
)

// Fingerprint returns a stable summary of local addresses, DNS servers, and the
// default route. It is best-effort; missing pieces are simply omitted.
func Fingerprint() string {
	var parts []string
	if ips := currentIPv4s(); len(ips) > 0 {
		parts = append(parts, "ip="+strings.Join(ips, ","))
	}
	if route := defaultRoute(); route != "" {
		parts = append(parts, "route="+route)
	}
	if dns := dnsServers(); len(dns) > 0 {
		parts = append(parts, "dns="+strings.Join(dns, ","))
	}
	return strings.Join(parts, "|")
}

func currentIPv4s() []string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	var ips []string
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			ipNet, ok := addr.(*net.IPNet)
			if !ok || ipNet.IP.IsLoopback() {
				continue
			}
			if ip4 := ipNet.IP.To4(); ip4 != nil {
				ips = append(ips, iface.Name+"="+ip4.String())
			}
		}
	}
	sort.Strings(ips)
	return ips
}

func dnsServers() []string {
	file, err := os.Open("/etc/resolv.conf")
	if err != nil {
		return nil
	}
	defer file.Close()

	seen := map[string]bool{}
	var servers []string
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 2 || fields[0] != "nameserver" {
			continue
		}
		server := fields[1]
		if !seen[server] {
			seen[server] = true
			servers = append(servers, server)
		}
	}
	sort.Strings(servers)
	return servers
}

func defaultRoute() string {
	out, err := exec.Command("route", "-n", "get", "default").CombinedOutput()
	if err != nil {
		return ""
	}
	var gateway, iface string
	scanner := bufio.NewScanner(bytes.NewReader(out))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		switch strings.TrimSpace(key) {
		case "gateway":
			gateway = strings.TrimSpace(value)
		case "interface":
			iface = strings.TrimSpace(value)
		}
	}
	if gateway == "" && iface == "" {
		return ""
	}
	return iface + "@" + gateway
}
