// Package pause 管理用户暂停状态，绑定设备启动周期。
// 设计：暂停标记里存 pause 当时的启动 id；重启/注销后启动 id 必变，标记自动失效。
// 移植自 bash 守护的巧妙设计，此处为 Go 跨平台实现。
package pause

// Controller 管理暂停状态。
type Controller interface {
	// Pause 暂停(记录当前启动 id)。
	Pause() error
	// Resume 恢复(清除标记)。
	Resume() error
	// IsPaused 当前是否处于暂停(标记存在且匹配当前启动 id)。
	IsPaused() bool
}

type defaultController struct {
	stateFile string
}

// New 创建暂停控制器，stateFile 是标记文件路径。
func New(stateFile string) Controller {
	return defaultController{stateFile: stateFile}
}

// 阶段 1 实现：读写 stateFile + 获取启动 id(sysctl kern.boottime)
func (defaultController) Pause() error   { return nil }
func (defaultController) Resume() error  { return nil }
func (defaultController) IsPaused() bool { return false }
