import AppKit
import QuartzCore

/// 调试用帧间隔探针：`--args -WgSenseFrameProbe 20` 启动后第 3 秒起记录 N 秒主线程帧间隔，
/// 结果写到 /tmp/wgsense-frames.txt（仅命令行参数域启用，不落盘设置）。
@MainActor
final class WgFrameProbe: NSObject {
    static var current: WgFrameProbe?
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var intervals: [Double] = []
    private var stamps: [Double] = []
    private var origin: CFTimeInterval = 0
    private var until: CFTimeInterval = 0
    private var expected: Double = 1.0 / 120

    static func startIfRequested() {
        let args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        guard let seconds = (args["WgSenseFrameProbe"] as? String).flatMap(Double.init) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let probe = WgFrameProbe()
            current = probe
            probe.start(seconds: seconds)
        }
    }

    private func start(seconds: Double) {
        guard let screen = NSScreen.main else { return }
        expected = 1.0 / Double(max(60, screen.maximumFramesPerSecond))
        let link = screen.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        until = CACurrentMediaTime() + seconds
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if origin == 0 { origin = now }
        if last > 0 { intervals.append(now - last); stamps.append(now - origin) }
        last = now
        if CACurrentMediaTime() > until { finish() }
    }

    private func finish() {
        link?.invalidate(); link = nil
        let ms = intervals.map { $0 * 1000 }.sorted()
        guard !ms.isEmpty else { return }
        func pct(_ p: Double) -> Double { ms[min(ms.count - 1, Int(Double(ms.count) * p))] }
        let hitches = ms.filter { $0 > expected * 1000 * 1.5 }.count
        let dropped = ms.reduce(0.0) { $0 + max(0, ($1 / (expected * 1000)).rounded() - 1) }
        let text = String(format: "frames %d  expected %.2fms  p50 %.2f  p95 %.2f  p99 %.2f  max %.1f  hitches(>1.5f) %d  dropped≈%.0f (%.1f%%)\n",
                          ms.count, expected * 1000, pct(0.5), pct(0.95), pct(0.99), ms.last!, hitches, dropped, dropped / Double(ms.count + Int(dropped)) * 100)
        let spikes = zip(intervals, stamps).filter { $0.0 > 0.04 }.map { String(format: "%.2fs:%.0fms", $0.1, $0.0 * 1000) }.joined(separator: " ")
        let report = text + "spikes>40ms: " + spikes + "\n"
        try? report.write(toFile: "/tmp/wgsense-frames.txt", atomically: true, encoding: .utf8)
    }
}
