package tunnel

import (
	"context"
	"fmt"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type systemVPN struct {
	Name  string
	State string
}

var (
	systemConnectionLine = regexp.MustCompile(`^\s*\*?\s*\(([^)]+)\)\s+([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})\s+(.+)$`)
	systemConnectionName = regexp.MustCompile(`"(?:\\.|[^"\\])*"`)
)

// activeSystemVPNs only recognizes VPN services reported by SystemConfiguration.
// An ordinary utun interface is not evidence that another VPN owns the network.
// Names are not ownership: an official WireGuard profile may be WgSense-default.
func activeSystemVPNs(output string) []systemVPN {
	var active []systemVPN
	for _, line := range strings.Split(output, "\n") {
		match := systemConnectionLine.FindStringSubmatch(line)
		if match == nil {
			continue
		}
		state, details := strings.TrimSpace(match[1]), strings.TrimSpace(match[3])
		switch strings.ToLower(state) {
		case "connected", "connecting", "disconnecting", "reasserting":
		default:
			continue
		}
		// PPP modem entries also appear in --nc list and are not VPN services.
		if !strings.Contains(details, "[VPN:") &&
			!strings.HasSuffix(details, "[IPSec]") &&
			!strings.HasSuffix(details, "[PPP:L2TP]") &&
			!strings.HasSuffix(details, "[PPP:PPTP]") {
			continue
		}
		name := match[2]
		if quoted := systemConnectionName.FindString(details); quoted != "" {
			if decoded, err := strconv.Unquote(quoted); err == nil {
				name = decoded
			}
		}
		active = append(active, systemVPN{Name: name, State: state})
	}
	return active
}

type systemVPNCommandRunner func(context.Context, string, ...string) ([]byte, error)

func ensureNoActiveSystemVPN() error {
	return checkSystemVPNs(func(ctx context.Context, name string, args ...string) ([]byte, error) {
		return exec.CommandContext(ctx, name, args...).CombinedOutput()
	})
}

func checkSystemVPNs(run systemVPNCommandRunner) error {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	out, err := run(ctx, "/usr/sbin/scutil", "--nc", "list")
	if err != nil {
		return fmt.Errorf("无法确认系统 VPN 状态，已取消 WgSense 连接: %w", err)
	}
	active := activeSystemVPNs(string(out))
	if len(active) == 0 {
		return nil
	}
	names := make([]string, 0, len(active))
	for _, vpn := range active {
		names = append(names, fmt.Sprintf("%s（%s）", vpn.Name, vpn.State))
	}
	return fmt.Errorf("检测到活动系统 VPN：%s；请先手动断开该 VPN 后再连接 WgSense", strings.Join(names, "、"))
}
