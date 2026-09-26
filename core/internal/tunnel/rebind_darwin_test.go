package tunnel

import (
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// newTestWatchdog 返回一个周期被压缩到毫秒级的看门狗，避免测试等待真实退避。
func newTestWatchdog() *bindWatchdog {
	w := newBindWatchdog()
	w.minInterval = 10 * time.Millisecond
	w.maxInterval = 80 * time.Millisecond
	w.settleDelay = 200 * time.Millisecond
	w.backoff = w.minInterval
	return w
}

// waitFor 轮询条件直到成立或超时，避免固定 sleep 造成的不稳定。
func waitFor(t *testing.T, timeout time.Duration, cond func() bool) bool {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if cond() {
			return true
		}
		time.Sleep(time.Millisecond)
	}
	return cond()
}

func TestBindErrorTriggersRebind(t *testing.T) {
	w := newTestWatchdog()
	var calls int64
	w.attachFunc(func() error {
		atomic.AddInt64(&calls, 1)
		return nil
	})
	defer w.detach()

	logger := newDeviceLogger(w)
	logger.Errorf("%v - Failed to send data packets: %v", "peer(abc)",
		errors.New("write udp4 0.0.0.0:54569->203.88.44.108:51820: sendmsg: can't assign requested address"))

	if !waitFor(t, time.Second, func() bool { return atomic.LoadInt64(&calls) == 1 }) {
		t.Fatalf("发包地址失效未触发重建，calls=%d", atomic.LoadInt64(&calls))
	}
}

func TestUnrelatedErrorDoesNotRebind(t *testing.T) {
	w := newTestWatchdog()
	var calls int64
	w.attachFunc(func() error {
		atomic.AddInt64(&calls, 1)
		return nil
	})
	defer w.detach()

	logger := newDeviceLogger(w)
	logger.Errorf("peer(abc) - Received invalid response message from 203.88.44.108:51820")
	logger.Errorf("peer(abc) - Failed to send handshake initiation: no route to host")

	time.Sleep(50 * time.Millisecond)
	if got := atomic.LoadInt64(&calls); got != 0 {
		t.Fatalf("无关错误不应触发重建，calls=%d", got)
	}
}

func TestBurstCollapsesToFewRebinds(t *testing.T) {
	w := newTestWatchdog()
	var calls int64
	w.attachFunc(func() error {
		atomic.AddInt64(&calls, 1)
		return nil
	})
	defer w.detach()

	logger := newDeviceLogger(w)
	// 模拟一次失效爆发：同一条错误在极短时间内刷出上千条。
	for i := 0; i < 2000; i++ {
		logger.Errorf("%v - Failed to send data packets: %v", "peer(abc)",
			errors.New("write udp4 0.0.0.0:54569->203.88.44.108:51820: sendmsg: can't assign requested address"))
	}

	if !waitFor(t, time.Second, func() bool { return atomic.LoadInt64(&calls) >= 1 }) {
		t.Fatal("爆发未触发任何重建")
	}
	time.Sleep(60 * time.Millisecond)
	// 冷却期吸收掉同一轮的剩余信号：2000 条错误不应换来 2000 次重建。
	if got := atomic.LoadInt64(&calls); got > 5 {
		t.Fatalf("一轮爆发触发了过多重建: %d", got)
	}
}

func TestRebindFailureBacksOff(t *testing.T) {
	w := newTestWatchdog()
	w.attachFunc(func() error { return errors.New("bind 失败") })
	defer w.detach()

	logger := newDeviceLogger(w)
	for i := 0; i < 5; i++ {
		logger.Errorf("%v - Failed to send data packets: %v", "peer(abc)",
			errors.New("sendmsg: can't assign requested address"))
		time.Sleep(20 * time.Millisecond)
	}

	if !waitFor(t, time.Second, func() bool { return w.currentBackoff() > w.minInterval }) {
		t.Fatalf("重建持续失败时退避未增长，backoff=%s", w.currentBackoff())
	}
	if w.currentBackoff() > w.maxInterval {
		t.Fatalf("退避超出上限: %s > %s", w.currentBackoff(), w.maxInterval)
	}
}

func TestRebindRetriesAfterFailureWithoutAnotherSendError(t *testing.T) {
	w := newTestWatchdog()
	var calls atomic.Int32
	w.attachFunc(func() error {
		if calls.Add(1) == 1 {
			return errors.New("listen udp4: bind: address already in use")
		}
		return nil
	})
	defer w.detach()

	// After a failed BindUpdate wireguard-go has no socket. Recovery must not
	// depend on another EADDRNOTAVAIL arriving from the now-closed socket.
	w.notify()
	if !waitFor(t, 300*time.Millisecond, func() bool { return calls.Load() >= 2 }) {
		t.Fatalf("failed bind was never retried without another send error: calls=%d", calls.Load())
	}
}

func TestDetachWaitsForInFlightRebind(t *testing.T) {
	w := newTestWatchdog()
	entered := make(chan struct{})
	release := make(chan struct{})
	w.attachFunc(func() error {
		close(entered)
		<-release
		return nil
	})
	w.notify()
	select {
	case <-entered:
	case <-time.After(time.Second):
		close(release)
		w.detach()
		t.Fatal("rebind did not start")
	}

	detached := make(chan struct{})
	go func() { w.detach(); close(detached) }()
	select {
	case <-detached:
		close(release)
		t.Fatal("detach returned while BindUpdate was still using the device")
	case <-time.After(25 * time.Millisecond):
	}
	close(release)
	select {
	case <-detached:
	case <-time.After(time.Second):
		t.Fatal("detach did not finish after BindUpdate returned")
	}
}

func TestDetachStopsRebinding(t *testing.T) {
	w := newTestWatchdog()
	var calls int64
	w.attachFunc(func() error {
		atomic.AddInt64(&calls, 1)
		return nil
	})

	logger := newDeviceLogger(w)
	w.detach()

	// 设备已销毁后仍可能有在途的发包错误，此时绝不能再碰设备。
	for i := 0; i < 100; i++ {
		logger.Errorf("%v - Failed to send data packets: %v", "peer(abc)",
			errors.New("sendmsg: can't assign requested address"))
	}
	time.Sleep(50 * time.Millisecond)

	if got := atomic.LoadInt64(&calls); got != 0 {
		t.Fatalf("detach 后不应再重建，calls=%d", got)
	}
}

func TestAttachAfterDetachWorks(t *testing.T) {
	w := newTestWatchdog()
	w.attachFunc(func() error { return nil })
	w.detach()

	var calls int64
	w.attachFunc(func() error {
		atomic.AddInt64(&calls, 1)
		return nil
	})
	defer w.detach()

	logger := newDeviceLogger(w)
	logger.Errorf("%v - Failed to send data packets: %v", "peer(abc)",
		errors.New("sendmsg: can't assign requested address"))

	if !waitFor(t, time.Second, func() bool { return atomic.LoadInt64(&calls) == 1 }) {
		t.Fatalf("重连后看门狗未恢复工作，calls=%d", atomic.LoadInt64(&calls))
	}
}

func TestNotifyIsNonBlocking(t *testing.T) {
	w := newTestWatchdog()
	// 故意不 attach：没有后台循环消费信号，notify 仍必须立即返回。
	done := make(chan struct{})
	go func() {
		for i := 0; i < 10000; i++ {
			w.notify()
		}
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("notify 在发包热路径上发生了阻塞")
	}
}

func TestLogFolderCollapsesRepeats(t *testing.T) {
	var mu sync.Mutex
	var lines []string
	f := &logFolder{printf: func(line string) {
		mu.Lock()
		defer mu.Unlock()
		lines = append(lines, line)
	}}

	for i := 0; i < 500; i++ {
		f.write("same failure")
	}
	f.write("different failure")

	mu.Lock()
	defer mu.Unlock()
	// 500 条相同 + 1 条不同，应折叠成：首条 + 重复计数 + 新的一条。
	if len(lines) > 4 {
		t.Fatalf("重复日志未被折叠，输出 %d 行: %v", len(lines), lines)
	}
	if len(lines) < 2 {
		t.Fatalf("折叠过度，丢失了日志: %v", lines)
	}
}

func TestLogFolderReportsRepeatCount(t *testing.T) {
	var mu sync.Mutex
	var lines []string
	f := &logFolder{printf: func(line string) {
		mu.Lock()
		defer mu.Unlock()
		lines = append(lines, line)
	}}

	f.write("boom")
	for i := 0; i < 9; i++ {
		f.write("boom")
	}
	f.flush()

	mu.Lock()
	defer mu.Unlock()
	var sawCount bool
	for _, line := range lines {
		if line == "重复 9 次: boom" {
			sawCount = true
		}
	}
	if !sawCount {
		t.Fatalf("折叠后未报告重复次数: %v", lines)
	}
}
