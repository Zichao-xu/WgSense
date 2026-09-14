package tunnel

import (
	"strings"
	"testing"
	"time"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/tuntest"
)

// 这组测试把看门狗接到真实的 wireguard-go 设备上：内存 TUN + 真实 UDP bind，
// 不需要 root，也不碰系统路由和 DNS。它们验证的是自愈手段本身安全——BindUpdate
// 能在运行中的设备上成功执行，且执行后设备仍然可用。上面 rebind_darwin_test.go
// 里的测试只覆盖触发与退避决策，不触碰真实设备。

// newLiveDevice 创建一个已启动的真实设备，返回设备与清理函数。
func newLiveDevice(t *testing.T, w *bindWatchdog) (*device.Device, func()) {
	t.Helper()
	tunDev := tuntest.NewChannelTUN()
	dev := device.NewDevice(tunDev.TUN(), conn.NewDefaultBind(), newDeviceLogger(w))
	if err := dev.Up(); err != nil {
		t.Fatalf("设备启动失败: %v", err)
	}
	return dev, func() { dev.Close() }
}

func TestBindUpdateSucceedsOnLiveDevice(t *testing.T) {
	w := newTestWatchdog()
	dev, cleanup := newLiveDevice(t, w)
	defer cleanup()

	// 这是自愈的核心动作：对一个正在运行的设备重建 UDP bind。
	if err := dev.BindUpdate(); err != nil {
		t.Fatalf("对运行中的设备重建 bind 失败: %v", err)
	}

	// 重建之后设备必须仍然可用，否则自愈就变成了故障放大。
	ipc, err := dev.IpcGet()
	if err != nil {
		t.Fatalf("重建 bind 后设备不可用: %v", err)
	}
	if !strings.Contains(ipc, "listen_port=") {
		t.Fatalf("重建 bind 后未监听端口: %q", ipc)
	}
}

func TestRepeatedBindUpdateKeepsDeviceUsable(t *testing.T) {
	w := newTestWatchdog()
	dev, cleanup := newLiveDevice(t, w)
	defer cleanup()

	// 网络频繁抖动时会连续触发重建，必须能承受。
	for i := 0; i < 10; i++ {
		if err := dev.BindUpdate(); err != nil {
			t.Fatalf("第 %d 次重建失败: %v", i+1, err)
		}
	}
	if _, err := dev.IpcGet(); err != nil {
		t.Fatalf("连续重建后设备不可用: %v", err)
	}
}

// TestWatchdogRebindsLiveDevice 走完整链路：发包错误 → logger → watchdog →
// 真实设备的 BindUpdate。
func TestWatchdogRebindsLiveDevice(t *testing.T) {
	w := newTestWatchdog()
	dev, cleanup := newLiveDevice(t, w)
	defer cleanup()

	w.attach(dev)
	defer w.detach()

	logger := newDeviceLogger(w)
	logger.Errorf("peer(abc) - Failed to send data packets: write udp4 0.0.0.0:54569->203.88.44.108:51820: sendmsg: %s",
		bindErrorNeedle)

	if !waitFor(t, 2*time.Second, func() bool { return w.rebindCount() >= 1 }) {
		t.Fatalf("完整链路未触发重建，count=%d", w.rebindCount())
	}
	// 重建计数增长的同时，设备必须还活着。
	if _, err := dev.IpcGet(); err != nil {
		t.Fatalf("自愈后设备不可用: %v", err)
	}
}

// TestDetachBeforeDeviceCloseIsSafe 复现 cleanup 的真实顺序：先摘看门狗再关设备，
// 期间仍有在途的发包错误。这条路径如果出错就是对已销毁设备的操作。
func TestDetachBeforeDeviceCloseIsSafe(t *testing.T) {
	w := newTestWatchdog()
	tunDev := tuntest.NewChannelTUN()
	dev := device.NewDevice(tunDev.TUN(), conn.NewDefaultBind(), newDeviceLogger(w))
	if err := dev.Up(); err != nil {
		t.Fatalf("设备启动失败: %v", err)
	}
	w.attach(dev)

	logger := newDeviceLogger(w)
	go func() {
		for i := 0; i < 200; i++ {
			logger.Errorf("peer(abc) - Failed to send data packets: sendmsg: %s", bindErrorNeedle)
		}
	}()

	// tunnel_darwin.go 的 cleanup 就是这个顺序。
	w.detach()
	dev.Close()

	// 再灌一轮在途错误，确认不会摸到已经关闭的设备。
	for i := 0; i < 200; i++ {
		logger.Errorf("peer(abc) - Failed to send data packets: sendmsg: %s", bindErrorNeedle)
	}
	time.Sleep(50 * time.Millisecond)
}
