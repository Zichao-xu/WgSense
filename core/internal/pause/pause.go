// Package pause 管理用户暂停状态，绑定设备启动周期。
// 设计：暂停标记里存 pause 当时的启动 id（开机秒数）；重启/注销后启动 id 必变，标记自动失效。
// 移植自 bash 守护的巧妙设计，此处为 Go 跨平台实现。
package pause

import (
	"os"
	"strings"
)

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

// bootID() 由平台文件 pause_bootid_*.go 实现，返回当前启动标识。

func (c defaultController) Pause() error {
	id := bootID()
	if id == "" {
		return nil
	}
	return os.WriteFile(c.stateFile, []byte(id), 0644)
}

func (c defaultController) Resume() error {
	err := os.Remove(c.stateFile)
	if os.IsNotExist(err) {
		return nil
	}
	return err
}

func (c defaultController) IsPaused() bool {
	data, err := os.ReadFile(c.stateFile)
	if err != nil {
		return false // 文件不存在 = 未暂停
	}
	saved := strings.TrimSpace(string(data))
	cur := bootID()
	if saved == "" || cur == "" {
		return false
	}
	if saved != cur {
		// 启动 id 变化（重启/注销），标记失效，清除
		_ = os.Remove(c.stateFile)
		return false
	}
	return true
}
