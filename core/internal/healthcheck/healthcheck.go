// Package healthcheck 检测 WireGuard 隧道的“假连接”状态。
// 睡眠唤醒后 NetworkExtension 可能谎报 Connected，实际 UDP 通道已失效；
// 本包通过连通性探测识别这种情况，触发强制 stop/start。
package healthcheck

import (
	"net/http"
	"time"
)

// Checker 检测隧道连通性。
type Checker interface {
	// CheckConnectivity 探测当前网络是否真的能出网。
	CheckConnectivity() bool
	// IsStaleConnected 判断是否处于“假连接”(状态 Connected 但不通)。
	IsStaleConnected(tunnelConnected bool) bool
}

type defaultChecker struct {
	target  string
	timeout time.Duration
}

// New 创建连通性探测器，target 是探测目标(如 "https://1.1.1.1")。
func New(target string) Checker {
	return defaultChecker{
		target:  target,
		timeout: 5 * time.Second,
	}
}

// CheckConnectivity 通过 HTTP HEAD 探测目标，5 秒超时。
// 任何 HTTP 响应都说明能出网（即使是 4xx/5xx）。
func (c defaultChecker) CheckConnectivity() bool {
	if c.target == "" {
		return true // 未配置探测目标，默认认为通
	}
	client := &http.Client{Timeout: c.timeout}
	resp, err := client.Head(c.target)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return true
}

func (c defaultChecker) IsStaleConnected(tunnelConnected bool) bool {
	if !tunnelConnected {
		return false
	}
	return !c.CheckConnectivity()
}
