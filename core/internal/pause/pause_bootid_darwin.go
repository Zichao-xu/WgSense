//go:build darwin

// Package pause 的 macOS 实现：从 sysctl kern.boottime 提取开机秒数。
package pause

import (
	"os/exec"
	"strings"
)

// bootID 返回 macOS 开机秒数（kern.boottime 的 sec 字段）。
// 重启/注销后此值必然变化，用作暂停标记的有效期校验。
func bootID() string {
	out, err := exec.Command("/usr/sbin/sysctl", "-n", "kern.boottime").Output()
	if err != nil {
		return ""
	}
	// 输出格式: { sec = 1234567890, usec = ... }
	s := string(out)
	idx := strings.Index(s, "sec = ")
	if idx < 0 {
		return ""
	}
	s = s[idx+6:]
	end := strings.IndexByte(s, ',')
	if end < 0 {
		return ""
	}
	return strings.TrimSpace(s[:end])
}
