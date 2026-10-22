package firewall

import (
	_ "embed"
	"fmt"
	"net"
	"net/netip"
	"sort"
	"strings"
)

// 国内 IP 段取自 OpenClash 的 china_ip_route / china_ip6_route。
//
//go:embed data/cn4.txt
var cn4Data string

//go:embed data/cn6.txt
var cn6Data string

// aiCIDRs 是 AI 服务自有、不与其他站点共用的地址段。
// OpenAI/Google 等走共享 CDN，只做域名级拦截，避免误伤。
var aiCIDRs = []string{
	"160.79.104.0/23", // Anthropic
	"2607:6bc0::/48",  // Anthropic
}

// localCIDRs 永远放行：本机、局域网、CGNAT/Tailscale、链路本地、组播、广播。
var localCIDRs = []string{
	"127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
	"169.254.0.0/16", "100.64.0.0/10", "224.0.0.0/4", "255.255.255.255/32",
	"::1/128", "fe80::/10", "fc00::/7", "ff00::/8",
}

var defaultAIDomains = []string{
	// Anthropic
	"claude.ai", "www.claude.ai", "claude.com", "www.claude.com", "code.claude.com",
	"anthropic.com", "www.anthropic.com", "api.anthropic.com", "console.anthropic.com",
	"statsig.anthropic.com", "platform.claude.com", "api.claude.ai", "a-api.anthropic.com",
	"claudeusercontent.com", "www.claudeusercontent.com",
	// OpenAI
	"openai.com", "www.openai.com", "chat.openai.com", "api.openai.com", "auth.openai.com",
	"platform.openai.com", "auth0.openai.com", "ios.chat.openai.com", "android.chat.openai.com",
	"chatgpt.com", "www.chatgpt.com", "ab.chatgpt.com", "sora.chatgpt.com", "sora.com",
	"cdn.oaistatic.com", "oaistatic.com", "oaiusercontent.com", "files.oaiusercontent.com",
	// Google
	"gemini.google.com", "bard.google.com", "aistudio.google.com", "notebooklm.google.com",
	"generativelanguage.googleapis.com", "alkalimakersuite-pa.clients6.google.com",
	"labs.google", "deepmind.google",
	// xAI
	"grok.com", "www.grok.com", "x.ai", "www.x.ai", "api.x.ai", "accounts.x.ai",
	// 其他
	"perplexity.ai", "www.perplexity.ai", "api.perplexity.ai",
	"poe.com", "www.poe.com",
	"api.githubcopilot.com", "copilot-proxy.githubusercontent.com",
	"cursor.com", "www.cursor.com", "api2.cursor.sh", "cursor.sh",
	"mistral.ai", "chat.mistral.ai", "api.mistral.ai",
}

// DefaultAIDomains 返回内置 AI 域名名单(副本)。
func DefaultAIDomains() []string {
	return append([]string(nil), defaultAIDomains...)
}

// RuleInput 是渲染 pf 规则的输入。
type RuleInput struct {
	Level      Level
	Interfaces []string // 为空表示所有接口(强制模式)
	Endpoints  []string // WG 服务器 IP，境外档放行
	CNFile     string   // 国内 IP 段表文件(几千条，不适合内联)
}

// RenderPF 生成加载进 WgSense 锚点的完整规则文本。
func RenderPF(in RuleInput) string {
	on := ""
	if len(in.Interfaces) > 0 {
		ifaces := append([]string(nil), in.Interfaces...)
		sort.Strings(ifaces)
		on = " on { " + strings.Join(ifaces, " ") + " }"
	}
	var b strings.Builder
	b.WriteString("# WgSense 出站拦截，自动生成，请勿手改\n")
	fmt.Fprintf(&b, "table <wgsense_ai> const { %s }\n", strings.Join(aiCIDRs, ", "))
	fmt.Fprintf(&b, "block return out quick%s to <wgsense_ai>\n", on)
	if in.Level != LevelForeign {
		return b.String()
	}
	fmt.Fprintf(&b, "table <wgsense_local> const { %s }\n", strings.Join(localCIDRs, ", "))
	fmt.Fprintf(&b, "table <wgsense_cn> const persist file %q\n", in.CNFile)
	fmt.Fprintf(&b, "pass out quick%s to <wgsense_local> no state\n", on)
	if eps := endpointAddrs(in.Endpoints); len(eps) > 0 {
		fmt.Fprintf(&b, "table <wgsense_endpoint> const { %s }\n", strings.Join(eps, ", "))
		fmt.Fprintf(&b, "pass out quick%s to <wgsense_endpoint> no state\n", on)
	}
	fmt.Fprintf(&b, "pass out quick%s to <wgsense_cn> no state\n", on)
	fmt.Fprintf(&b, "block return out quick%s all\n", on)
	return b.String()
}

// CNTable 返回国内 IP 段表文件内容，一行一段。
func CNTable() string {
	return strings.Join(cnCIDRs(), "\n") + "\n"
}

func cnCIDRs() []string {
	var out []string
	for _, data := range []string{cn4Data, cn6Data} {
		for _, line := range strings.Split(data, "\n") {
			if line = strings.TrimSpace(line); line != "" {
				if _, err := netip.ParsePrefix(line); err == nil {
					out = append(out, line)
				}
			}
		}
	}
	return out
}

func endpointAddrs(in []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, ep := range in {
		addr, err := netip.ParseAddr(ep)
		if err != nil || seen[addr.String()] {
			continue
		}
		seen[addr.String()] = true
		out = append(out, addr.String())
	}
	sort.Strings(out)
	return out
}

// tunnelPrefixes 是隧道/虚拟出口，流量最终会从物理网卡出去时再被拦。
var tunnelPrefixes = []string{"lo", "utun", "ipsec", "ppp", "gif", "stf", "tun", "tap"}

func physicalInterfaces() []string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	var out []string
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		if isTunnelInterface(iface.Name) {
			continue
		}
		out = append(out, iface.Name)
	}
	sort.Strings(out)
	return out
}

func isTunnelInterface(name string) bool {
	for _, prefix := range tunnelPrefixes {
		if strings.HasPrefix(name, prefix) {
			return true
		}
	}
	return false
}
