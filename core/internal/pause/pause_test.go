package pause

import (
	"os"
	"testing"
)

func TestBootID(t *testing.T) {
	id := bootID()
	if id == "" {
		t.Skip("bootID 为空（sysctl 不可用？）")
	}
	// 两次调用应一致（同一启动周期内稳定）
	if bootID() != id {
		t.Error("bootID 不稳定")
	}
	t.Logf("当前 bootID: %s", id)
}

func TestPauseResume(t *testing.T) {
	tmp, _ := os.CreateTemp("", "pause-*")
	tmp.Close()
	defer os.Remove(tmp.Name())

	c := New(tmp.Name())
	if c.IsPaused() {
		t.Error("初始应未暂停")
	}
	if err := c.Pause(); err != nil {
		t.Fatal(err)
	}
	if !c.IsPaused() {
		t.Error("Pause 后应暂停")
	}
	if err := c.Resume(); err != nil {
		t.Fatal(err)
	}
	if c.IsPaused() {
		t.Error("Resume 后应未暂停")
	}
}

func TestIsPausedNoFile(t *testing.T) {
	c := New("/nonexistent/path/pause-marker")
	if c.IsPaused() {
		t.Error("文件不存在时应未暂停")
	}
}
