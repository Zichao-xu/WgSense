// macOS 上 wireguard-go 的 UDP socket 绑定在 0.0.0.0，并为每个 peer 缓存发包
// 时使用的源地址。Wi-Fi 重连、睡眠唤醒或地址变更之后，那个源地址可能已经不在
// 任何网卡上，内核于是对每一个发包返回 EADDRNOTAVAIL：
//
//	write udp4 0.0.0.0:54569->203.88.44.108:51820: sendmsg: can't assign requested address
//
// 此时收包方向仍然可用——对端发起的握手照常被接收并回应——所以设备对象还在、
// last_handshake 还在刷新，出方向却已经完全中断，表现为"显示已连接但流量为零"。
//
// 官方 macOS 客户端的处理是在 NWPathMonitor 回调里调用 wgBumpSockets，也就是
// device.BindUpdate()：关闭旧 socket、按原端口重开、清除每个 peer 缓存的源地址。
// 这里用同一手段，但触发信号直接取自发包错误本身，不必猜测网络何时变化，也不必
// 拆掉整条隧道重建。
package tunnel

import (
	"fmt"
	"log"
	"os"
	"strings"
	"sync"
	"time"

	"golang.zx2c4.com/wireguard/device"
)

// bindErrorNeedle 是 EADDRNOTAVAIL 在 Go 里的字符串形式。wireguard-go 只把发包
// 错误交给 Logger.Errorf，不提供结构化回调，所以这里按文本匹配。
const bindErrorNeedle = "can't assign requested address"

const (
	// rebindMinInterval 是两次 BindUpdate 之间的最小冷却。一次失效会在毫秒级
	// 内刷出成百上千条相同错误，重建一次就够，其余应当被吸收掉。
	rebindMinInterval = 2 * time.Second
	// rebindMaxInterval 是退避上限。物理网络真的断了的时候，重建不可能成功，
	// 此时应当降低频率静待恢复，而不是空转。
	rebindMaxInterval = 30 * time.Second
	// rebindSettleDelay 是判定"已经恢复"的安静期。超过这段时间没有新的失效
	// 信号，退避重置回最小值，下一次故障才能得到最快的响应。
	rebindSettleDelay = 45 * time.Second
	// logFoldWindow 是相同日志行的折叠窗口。
	logFoldWindow = 5 * time.Second
)

// bindWatchdog 监听发包失效信号并重建 UDP bind。它挂在设备的生命周期上：
// attach 随设备创建，detach 随 cleanup 结束。
type bindWatchdog struct {
	mu       sync.Mutex
	rebindFn func() error
	done     chan struct{}
	trigger  chan struct{}

	backoff time.Duration
	lastAt  time.Time
	total   int
	folder  *logFolder

	// 时间参数，默认取上面的常量；测试注入更短的周期。
	minInterval time.Duration
	maxInterval time.Duration
	settleDelay time.Duration
}

func newBindWatchdog() *bindWatchdog {
	return &bindWatchdog{
		trigger:     make(chan struct{}, 1),
		backoff:     rebindMinInterval,
		folder:      &logFolder{prefix: "ERROR: wgsense"},
		minInterval: rebindMinInterval,
		maxInterval: rebindMaxInterval,
		settleDelay: rebindSettleDelay,
	}
}

// attach 绑定新建的设备并启动后台循环。重复 attach 会先解绑旧设备。
func (w *bindWatchdog) attach(dev *device.Device) {
	w.attachFunc(dev.BindUpdate)
}

// attachFunc 是 attach 的可注入形式，便于在没有真实设备的情况下测试。
func (w *bindWatchdog) attachFunc(rebind func() error) {
	w.detach()

	w.mu.Lock()
	defer w.mu.Unlock()
	w.rebindFn = rebind
	w.backoff = w.minInterval
	w.lastAt = time.Time{}
	done := make(chan struct{})
	w.done = done
	go w.loop(done)
}

// detach 停止后台循环并解绑设备，供 cleanup 调用。解绑后即使仍有信号在途，
// 重建函数已置空，后台循环会直接放弃，不会碰到正在销毁的设备。
func (w *bindWatchdog) detach() {
	w.mu.Lock()
	done := w.done
	w.done = nil
	w.rebindFn = nil
	w.mu.Unlock()

	if done != nil {
		close(done)
	}
	w.folder.flush()
}

// notify 由 wireguard-go 的 Errorf 在发包热路径上调用，必须立即返回。这里只投递
// 一个信号，真正的重建在后台循环里做。
func (w *bindWatchdog) notify() {
	select {
	case w.trigger <- struct{}{}:
	default:
		// 已有待处理信号，丢弃。一轮爆发只需要重建一次。
	}
}

func (w *bindWatchdog) loop(done chan struct{}) {
	for {
		select {
		case <-done:
			return
		case <-w.trigger:
			w.rebind()
			// 冷却期内吸收掉同一轮爆发的剩余信号。
			select {
			case <-done:
				return
			case <-time.After(w.currentBackoff()):
			}
			w.drainTrigger()
		}
	}
}

func (w *bindWatchdog) drainTrigger() {
	select {
	case <-w.trigger:
	default:
	}
}

func (w *bindWatchdog) currentBackoff() time.Duration {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.backoff
}

// rebind 执行一次 BindUpdate，并按结果调整退避。
func (w *bindWatchdog) rebind() {
	w.mu.Lock()
	rebind := w.rebindFn
	if rebind == nil {
		w.mu.Unlock()
		return
	}
	// 距上次重建足够久，说明上一轮故障已经过去，退避重置。
	if !w.lastAt.IsZero() && time.Since(w.lastAt) > w.settleDelay {
		w.backoff = w.minInterval
	}
	w.lastAt = time.Now()
	w.total++
	attempt := w.total
	w.mu.Unlock()

	w.folder.flush()
	if err := rebind(); err != nil {
		w.mu.Lock()
		w.backoff *= 2
		if w.backoff > w.maxInterval {
			w.backoff = w.maxInterval
		}
		next := w.backoff
		w.mu.Unlock()
		log.Printf("[tunnel] UDP bind 重建失败（第 %d 次）: %v，%s 后重试", attempt, err, next)
		return
	}
	log.Printf("[tunnel] 检测到发包地址失效，已重建 UDP bind（第 %d 次）", attempt)
}

// rebindCount 返回累计重建次数，供状态快照使用。
func (w *bindWatchdog) rebindCount() int {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.total
}

// logFolder 折叠连续重复的日志行。一次 bind 失效会刷出上千条完全相同的错误，
// 原样打印会把真正有诊断价值的行淹没掉，也是日志文件膨胀的主因。
type logFolder struct {
	mu      sync.Mutex
	prefix  string
	last    string
	repeats int
	firstAt time.Time

	// printf 默认写标准日志；测试注入后可以断言折叠行为。
	printf func(string)
}

func (f *logFolder) emit(line string) {
	if f.prefix != "" {
		line = f.prefix + ": " + line
	}
	if f.printf != nil {
		f.printf(line)
		return
	}
	log.Print(line)
}

// write 打印一行；与上一行相同时只累计次数，等到出现新行或 flush 时再汇总输出。
func (f *logFolder) write(line string) {
	f.mu.Lock()
	if line == f.last && time.Since(f.firstAt) < logFoldWindow {
		f.repeats++
		f.mu.Unlock()
		return
	}
	pending, repeats := f.last, f.repeats
	f.last = line
	f.repeats = 0
	f.firstAt = time.Now()
	f.mu.Unlock()

	if repeats > 0 {
		f.emit(fmt.Sprintf("重复 %d 次: %s", repeats, pending))
	}
	f.emit(line)
}

// flush 输出尚未汇总的重复计数，用于设备销毁或重建前后收尾。
func (f *logFolder) flush() {
	f.mu.Lock()
	pending, repeats := f.last, f.repeats
	f.last = ""
	f.repeats = 0
	f.mu.Unlock()

	if repeats > 0 {
		f.emit(fmt.Sprintf("重复 %d 次: %s", repeats, pending))
	}
}

// newDeviceLogger 构造 wireguard-go 的日志器：
//   - 错误全部保留，但连续重复的行会被折叠；识别到发包地址失效时唤醒 watchdog。
//   - 调试日志默认丢弃。keepalive 每 25 秒一条，长期运行能把日志文件堆到几十 MB，
//     而排障需要的信息都在 ERROR 级别里。设 WGSENSE_WG_VERBOSE=1 可以打开。
func newDeviceLogger(w *bindWatchdog) *device.Logger {
	logger := &device.Logger{
		Verbosef: device.DiscardLogf,
		Errorf: func(format string, args ...any) {
			line := fmt.Sprintf(format, args...)
			w.folder.write(line)
			if strings.Contains(line, bindErrorNeedle) {
				w.notify()
			}
		},
	}
	if os.Getenv("WGSENSE_WG_VERBOSE") == "1" {
		logger.Verbosef = func(format string, args ...any) {
			log.Printf("DEBUG: wgsense: %s", fmt.Sprintf(format, args...))
		}
	}
	return logger
}
