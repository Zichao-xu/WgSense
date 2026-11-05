package firewall

import (
	"context"
	"fmt"
	"net"
	"net/netip"
	"regexp"
	"sort"
	"strings"
	"time"
)

// AllowedHost 是一个放行项当前解析到的地址，供 UI 展示；解析不到时 IPs 为空。
type AllowedHost struct {
	Host string   `json:"host"`
	IPs  []string `json:"ips"`
}

// hostTTL 是放行域名的重新解析间隔；DDNS 换 IP 后最迟这么久跟上。
const hostTTL = time.Minute

var hostnamePattern = regexp.MustCompile(`^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$`)

var fakeIPPrefix = netip.MustParsePrefix(fakeIPCIDR)

type hostEntry struct {
	ips []string
	at  time.Time
}

// NormalizeHosts 清理用户输入的放行项：去空白、转小写、去重；不是域名或 IP 就报错。
// 返回值永远非 nil，这样 API 总会带上 allow_hosts，界面据此判断服务是否支持。
func NormalizeHosts(in []string) ([]string, error) {
	out := make([]string, 0, len(in))
	seen := map[string]bool{}
	for _, raw := range in {
		host := strings.ToLower(strings.TrimSuffix(strings.TrimSpace(raw), "."))
		if host == "" || seen[host] {
			continue
		}
		if _, err := netip.ParseAddr(host); err != nil && !hostnamePattern.MatchString(host) {
			return nil, fmt.Errorf("不是有效的域名或 IP: %q", raw)
		}
		seen[host] = true
		out = append(out, host)
	}
	return out, nil
}

// lookupHost 用系统解析器查询，2 秒内没结果算失败。
func lookupHost(host string) []string {
	ctx, done := context.WithTimeout(context.Background(), 2*time.Second)
	defer done()
	addrs, err := net.DefaultResolver.LookupHost(ctx, host)
	if err != nil {
		return nil
	}
	return addrs
}

// realAddrs 只留真实地址。代理开着时系统 DNS 可能答 fake-ip，它不是节点的地址，
// 算作解析失败，才不会把上次解析到的真实 IP 顶掉。
func realAddrs(in []string) []string {
	var out []string
	for _, raw := range in {
		addr, err := netip.ParseAddr(raw)
		if err != nil {
			continue
		}
		addr = addr.Unmap()
		if addr.IsUnspecified() || addr.IsLoopback() || fakeIPPrefix.Contains(addr) {
			continue
		}
		out = append(out, addr.String())
	}
	sort.Strings(out)
	return out
}

// resolveAllowHosts 返回各放行项当前的地址。解析失败时沿用上次结果，
// DNS 抖一下不会断掉正在用的节点。调用方持有 c.mu。
func (c *Controller) resolveAllowHosts(hosts []string) []AllowedHost {
	cache := make(map[string]hostEntry, len(hosts))
	out := make([]AllowedHost, 0, len(hosts))
	now := time.Now()
	for _, host := range hosts {
		entry := c.hostCache[host]
		if entry.at.IsZero() || now.Sub(entry.at) >= hostTTL {
			if ips := realAddrs(c.ResolveHost(host)); len(ips) > 0 {
				entry.ips = ips
			}
			entry.at = now
		}
		cache[host] = entry
		out = append(out, AllowedHost{Host: host, IPs: entry.ips})
	}
	c.hostCache = cache
	return out
}
