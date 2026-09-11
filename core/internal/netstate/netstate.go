// Package netstate builds a lightweight fingerprint of the current network.
package netstate

import (
	"bufio"
	"bytes"
	"os/exec"
	"strings"

	"github.com/wgsense/core/internal/location"
)

// Fingerprint returns a stable summary of effective physical network addresses
// and the default route. It is best-effort; missing pieces are simply omitted.
func Fingerprint() string {
	var parts []string
	if network := location.NetworkFingerprint(); network != "" {
		parts = append(parts, "physical="+network)
	}
	if route := defaultRoute(); route != "" {
		parts = append(parts, "route="+route)
	}
	return strings.Join(parts, "|")
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
