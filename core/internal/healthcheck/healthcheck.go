// Package healthcheck 检测 WireGuard 隧道的“假连接”状态。
// 睡眠唤醒后 NetworkExtension 可能谎报 Connected，实际 UDP 通道已失效；
// 本包通过连通性探测识别这种情况，触发强制 stop/start。
package healthcheck

// Checker 检测隧道连通性。
type Checker interface {
	// CheckConnectivity 探测当前网络是否真的能出网。
	CheckConnectivity() bool
	// IsStaleConnected 判断是否处于“假连接”(状态 Connected 但不通)。
	IsStaleConnected(tunnelConnected bool) bool
}

type defaultChecker struct {
	target string
}

// New 创建连通性探测器，target 是探测目标(如 "https://1.1.1.1")。
func New(target string) Checker {
	return defaultChecker{target: target}
}

func (defaultChecker) CheckConnectivity() bool {
	// 阶段 1 实现：HTTP HEAD 探测 + 超时
	return true
}

func (c defaultChecker) IsStaleConnected(tunnelConnected bool) bool {
	if !tunnelConnected {
		return false
	}
	return !c.CheckConnectivity()
}
