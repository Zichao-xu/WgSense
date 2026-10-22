package firewall

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

// Anchor 挂在系统 pf.conf 自带的 `anchor "com.apple/*"` 下，不需要改 /etc/pf.conf。
const Anchor = "com.apple/wgsense"

const (
	hostsPath   = "/private/etc/hosts"
	hostsBegin  = "# >>> WgSense 出站拦截（由 WgSense 管理，关闭拦截后自动移除）>>>"
	hostsEnd    = "# <<< WgSense 出站拦截 <<<"
	pfctl       = "/sbin/pfctl"
	systemPFCfg = "/etc/pf.conf"
)

var tokenPattern = regexp.MustCompile(`Token\s*:\s*(\d+)`)

// System 是真实的 macOS 后端：pfctl + /etc/hosts。需要 root。
type System struct{}

func run(name string, args ...string) (string, error) {
	out, err := exec.Command(name, args...).CombinedOutput()
	if err != nil {
		return string(out), fmt.Errorf("%s %s: %w: %s", filepath.Base(name), strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return string(out), nil
}

func tokenPath() string { return filepath.Join(StateDir, "pf.token") }

func writeIfChanged(path, content string, mode os.FileMode) error {
	if old, err := os.ReadFile(path); err == nil && string(old) == content {
		return nil
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(content), mode); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// ApplyPF 写入规则、确保主规则集引用了 com.apple 锚点并启用 pf。
func (System) ApplyPF(rules string) error {
	if err := os.MkdirAll(StateDir, 0700); err != nil {
		return err
	}
	if err := writeIfChanged(CNTablePath(), CNTable(), 0600); err != nil {
		return err
	}
	rulesPath := filepath.Join(StateDir, "rules.conf")
	if err := writeIfChanged(rulesPath, rules, 0600); err != nil {
		return err
	}
	// 主规则集被别的工具替换过时，com.apple/* 挂载点可能不在；重载系统默认配置补回。
	if out, err := run(pfctl, "-s", "rules"); err != nil || !strings.Contains(out, `anchor "com.apple/*"`) {
		if _, err := run(pfctl, "-f", systemPFCfg); err != nil {
			return err
		}
	}
	if _, err := run(pfctl, "-a", Anchor, "-f", rulesPath); err != nil {
		return err
	}
	return ensureEnabled()
}

// ensureEnabled 持有一个 pf 启用引用(-E 令牌)，与系统其他使用者互不干扰。
func ensureEnabled() error {
	info, _ := run(pfctl, "-s", "info")
	_, tokenErr := os.Stat(tokenPath())
	if strings.Contains(info, "Status: Enabled") && tokenErr == nil {
		return nil
	}
	out, err := run(pfctl, "-E")
	if err != nil {
		return err
	}
	match := tokenPattern.FindStringSubmatch(out)
	if match == nil {
		return fmt.Errorf("pfctl -E 未返回令牌: %s", strings.TrimSpace(out))
	}
	return os.WriteFile(tokenPath(), []byte(match[1]+"\n"), 0600)
}

// ClearPF 清空 WgSense 锚点并归还 pf 启用引用。
func (System) ClearPF() error {
	if _, err := run(pfctl, "-a", Anchor, "-F", "all"); err != nil &&
		!strings.Contains(err.Error(), "No such file") && !strings.Contains(err.Error(), "does not exist") {
		return err
	}
	if data, err := os.ReadFile(tokenPath()); err == nil {
		// 令牌在重启后失效，归还失败无需报错。
		_, _ = run(pfctl, "-X", strings.TrimSpace(string(data)))
		_ = os.Remove(tokenPath())
	}
	return nil
}

// ApplyHosts 用标记段替换 /etc/hosts 里 WgSense 的部分；domains 为空则移除。
func (System) ApplyHosts(domains []string) error {
	data, err := os.ReadFile(hostsPath)
	if err != nil {
		return err
	}
	next := RenderHosts(string(data), domains)
	if next == string(data) {
		return nil
	}
	if err := writeIfChanged(hostsPath, next, 0644); err != nil {
		return err
	}
	_ = os.Chmod(hostsPath, 0644)
	_, _ = run("/usr/bin/dscacheutil", "-flushcache")
	_, _ = run("/usr/bin/killall", "-HUP", "mDNSResponder")
	return nil
}

// RenderHosts 返回替换 WgSense 段之后的 hosts 内容。
func RenderHosts(current string, domains []string) string {
	var kept []string
	inside := false
	for _, line := range strings.Split(current, "\n") {
		switch {
		case line == hostsBegin:
			inside = true
		case line == hostsEnd:
			inside = false
		case !inside:
			kept = append(kept, line)
		}
	}
	base := strings.TrimRight(strings.Join(kept, "\n"), "\n") + "\n"
	if len(domains) == 0 {
		return base
	}
	var b strings.Builder
	b.WriteString(base)
	b.WriteString(hostsBegin + "\n")
	for _, d := range domains {
		fmt.Fprintf(&b, "0.0.0.0 %s\n:: %s\n", d, d)
	}
	b.WriteString(hostsEnd + "\n")
	return b.String()
}
