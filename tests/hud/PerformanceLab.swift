import AppKit
import QuartzCore
import SwiftUI
import os.signpost

// A standalone, synthetic HUD host. It links no daemon, VPN or networking code.
// Canvas draw completion is deliberately measured separately from display-link callbacks.
// Neither metric alone proves that the compositor presented every frame.
private struct HUDFrameRecord: Codable {
    let timestamp: Double
    let cpuMilliseconds: Double
}

private struct HUDIntervalSummary: Codable {
    var samples = 0
    var effectiveFramesPerSecond: Double = 0
    var medianMilliseconds: Double = 0
    var p95Milliseconds: Double = 0
    var p99Milliseconds: Double = 0
    var maxMilliseconds: Double = 0
    var over12_5Milliseconds = 0
    var over25Milliseconds = 0

    init(_ seconds: [Double]) {
        let ms = seconds.filter { $0 > 0 }.map { $0 * 1000 }.sorted()
        samples = ms.count
        guard !ms.isEmpty else { return }
        func p(_ quantile: Double) -> Double { ms[min(ms.count - 1, Int(Double(ms.count - 1) * quantile))] }
        effectiveFramesPerSecond = 1000 * Double(ms.count) / ms.reduce(0, +)
        medianMilliseconds = p(0.5)
        p95Milliseconds = p(0.95)
        p99Milliseconds = p(0.99)
        maxMilliseconds = ms.last!
        over12_5Milliseconds = ms.filter { $0 > 12.5 }.count
        over25Milliseconds = ms.filter { $0 > 25 }.count
    }
}

@MainActor
private final class HUDRecorder: NSObject {
    private var link: CADisplayLink?
    private var frames: [HUDFrameRecord] = []
    private var displayTimes: [Double] = []
    private var started = Date.distantFuture
    private var ends = Date.distantPast
    private var mode = ""
    private var screen: NSScreen?
    private var completion: ((String) -> Void)?
    private var configuration: [String: String] = [:]
    private let traceLog = OSLog(subsystem: "local.wgsense.synthetic.hudlab", category: .pointsOfInterest)
    private var traceID = OSSignpostID.invalid
    var recording = false

    func draw(at date: Date, cpu: Double) {
        guard recording, date >= started, date < ends else { return }
        frames.append(HUDFrameRecord(timestamp: date.timeIntervalSinceReferenceDate, cpuMilliseconds: cpu * 1000))
    }

    func begin(mode: String, seconds: Double, window: NSWindow?, configuration: [String: String], completion: @escaping (String) -> Void) {
        link?.invalidate()
        self.mode = mode
        self.screen = window?.screen ?? NSScreen.main
        self.completion = completion
        self.configuration = configuration
        frames.removeAll(keepingCapacity: true)
        displayTimes.removeAll(keepingCapacity: true)
        // Do not count layout/warmup or the control button's click redraw.
        started = Date().addingTimeInterval(2)
        ends = started.addingTimeInterval(seconds)
        recording = true
        traceID = OSSignpostID(log: traceLog)
        os_signpost(.begin, log: traceLog, name: "HUD Scenario", signpostID: traceID, "%{public}s", mode)
        if let screen {
            let link = screen.displayLink(target: self, selector: #selector(displayTick(_:)))
            // A probe must not request a faster rate than production uses.
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2 + seconds) { [weak self] in self?.finish() }
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        let now = Date()
        guard recording, now >= started, now < ends else { return }
        displayTimes.append(link.timestamp)
    }

    private func finish() {
        guard recording else { return }
        recording = false
        os_signpost(.end, log: traceLog, name: "HUD Scenario", signpostID: traceID, "%{public}s", mode)
        link?.invalidate()
        link = nil
        func intervals(_ times: [Double]) -> [Double] { zip(times.dropFirst(), times).map(-) }
        // More than one Canvas may be prepared inside one refresh because ViewThatFits
        // evaluates candidates. Count redraw bursts separately; do not inflate fps.
        var visibleBursts: [Double] = []
        for frame in frames {
            if let last = visibleBursts.last, frame.timestamp - last < 0.002 { continue }
            visibleBursts.append(frame.timestamp)
        }
        let cadence = HUDIntervalSummary(intervals(visibleBursts))
        let cpu = frames.map(\.cpuMilliseconds).sorted()
        func cpuP(_ p: Double) -> Double { cpu.isEmpty ? 0 : cpu[min(cpu.count - 1, Int(Double(cpu.count - 1) * p))] }
        let summary: [String: Any] = [
            "mode": mode,
            "scenarioConfiguration": configuration,
            "measuredSeconds": ends.timeIntervalSince(started),
            "finishedAt": ISO8601DateFormatter().string(from: Date()),
            "app": "WgHUDLab (synthetic, isolated renderer)",
            "screenName": screen?.localizedName ?? "unknown",
            "screenMaximumFramesPerSecond": screen?.maximumFramesPerSecond ?? 0,
            "screenMinimumRefreshMilliseconds": (screen?.minimumRefreshInterval ?? 0) * 1000,
            "screenMaximumRefreshMilliseconds": (screen?.maximumRefreshInterval ?? 0) * 1000,
            "backingScaleFactor": screen?.backingScaleFactor ?? 0,
            "lowPowerModeEnabled": ProcessInfo.processInfo.isLowPowerModeEnabled,
            "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
            "target120HzBudgetMilliseconds": 1000.0 / 120.0,
            "windowVisible": NSApp.windows.first?.isVisible ?? false,
            "windowOcclusionVisible": NSApp.windows.first?.occlusionState.contains(.visible) ?? false,
            "rawCanvasDrawCount": frames.count,
            "canvasDrawBurstCount": visibleBursts.count,
            "drawsInside2msSameBurst": frames.count - visibleBursts.count,
            "canvasCpuMedianMilliseconds": cpuP(0.5),
            "canvasCpuP95Milliseconds": cpuP(0.95),
            "canvasCpuMaxMilliseconds": cpu.last ?? 0,
            "canvasCpuCountExceeding120HzBudget": cpu.filter { $0 > 1000.0 / 120.0 }.count,
            "canvasCpuScope": "Animated Canvas draw closure only; excludes retained static layer, SwiftUI layout, GPU and compositor presentation.",
            "canvasCadence": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(cadence))) ?? [:],
            "displayCallbackCadence": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(HUDIntervalSummary(intervals(displayTimes))))) ?? [:],
            "evidenceBoundary": "Canvas submission cadence and CPU cost. Display callbacks are an independent scheduling reference, not presented frames. Animation Hitches/Core Animation trace is required to establish compositor presentation.",
            "rawCanvasFrames": frames.map { ["timestamp": $0.timestamp, "cpuMilliseconds": $0.cpuMilliseconds] },
            "rawDisplayTimestamps": displayTimes
        ]
        do {
            let root = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("PerformanceReports")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let timestamp = Int(Date().timeIntervalSince1970)
            let output = root.appendingPathComponent("\(mode)-\(timestamp).json")
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: output)
            let title = ["events": "事件压测", "interaction": "交互采样", "idle": "静止采样", "reduced": "减少动态", "pointer-stress": "指针压测"][mode] ?? "采样"
            let result = String(format: "%@ · 重绘 %d · %.1f fps · 间隔 P95 %.2f ms · 绘制 P95 %.2f ms", title, frames.count, cadence.effectiveFramesPerSecond, cadence.p95Milliseconds, cpuP(0.95))
            completion?(result + "\n" + output.path)
        } catch {
            completion?("报告写入失败：\(error.localizedDescription)")
        }
        completion = nil
    }
}

@MainActor
private final class HUDLabState: NSObject, ObservableObject {
    let monitor = WgLinkMonitor()
    let recorder = HUDRecorder()
    @Published var phase: WgLinkPhase = .linked
    @Published var reduced = false
    @Published var compact = false
    @Published var light = false
    @Published var busy = false
    @Published var syntheticPointer: CGPoint?
    @Published var report = "移入、拖动并点击舞台查看交互。所有数据均为合成。"
    private var timer: Timer?
    private var rx: UInt64 = 0
    private var tx: UInt64 = 0
    private var sequence = 0
    private var rebinds = 0
    private var activeMode = ""
    private var startedAt = Date()
    private var pointerLink: CADisplayLink?

    override init() {
        super.init()
        let now = Date()
        for i in 0...24 {
            rx += UInt64(1_800_000 + ((i * 7919) % 240000) * 7)
            tx += UInt64(80_000 + ((i * 3571) % 15000) * 2)
            monitor.ingest(handshake: "hs-0", handshakeAge: 8 + i * 2,
                           tx: tx, rx: rx, rebinds: 0, tunnelUp: true,
                           at: now.addingTimeInterval(Double(i * 2 - 48)))
        }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
    }

    private func sample() {
        sequence += 1
        let elapsed = Date().timeIntervalSince(startedAt)
        let stress = busy && (activeMode == "events" || activeMode == "reduced")
        rx += UInt64(stress ? 1_000_000 + (sequence % 5) * 1_800_000 : 2_000_000)
        tx += UInt64(stress ? 30_000 + (sequence % 4) * 120_000 : 90_000)
        if stress && elapsed > 5 && sequence % 2 == 0 { rebinds += 1 }
        monitor.ingest(handshake: stress ? "hs-\(sequence)" : "hs-steady", handshakeAge: stress ? 0 : 20,
                       tx: tx, rx: rx, rebinds: rebinds, tunnelUp: true)
    }

    func measure(_ mode: String) {
        guard !busy else { return }
        busy = true
        activeMode = mode
        startedAt = Date()
        reduced = mode == "reduced"
        report = mode == "interaction" ? "交互采样：请在舞台内持续移入、拖动、点击。" : "采样中，结束后自动保存报告。"
        if mode == "pointer-stress", let screen = NSApp.windows.first?.screen ?? NSScreen.main {
            let link = screen.displayLink(target: self, selector: #selector(pointerTick(_:)))
            // Leave refresh-rate negotiation to the production HUD clock. A stronger
            // preference here would make the test pass while changing its subject.
            link.add(to: .main, forMode: .common)
            pointerLink = link
        }
        recorder.begin(mode: mode, seconds: mode == "idle" ? 8 : 12, window: NSApp.windows.first,
                       configuration: ["widthPoints": compact ? "430" : "900", "colorScheme": light ? "light" : "dark",
                                       "reduceMotion": reduced ? "true" : "false", "inputDriver": mode == "pointer-stress" ? "synthetic display callback; no frame rate override" : "production events/manual input"]) { [weak self] text in
            self?.pointerLink?.invalidate()
            self?.pointerLink = nil
            self?.syntheticPointer = nil
            self?.busy = false
            self?.activeMode = ""
            self?.report = text
        }
    }

    @objc private func pointerTick(_ link: CADisplayLink) {
        let t = Date().timeIntervalSince(startedAt)
        let width: Double = compact ? 430 : 900
        syntheticPointer = CGPoint(x: width * 0.32 + sin(t * 2.8) * width * 0.22,
                                   y: 150 + sin(t * 4.3 + 0.8) * 82)
    }
}

private struct HUDLabView: View {
    @StateObject private var state = HUDLabState()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("动态 HUD · 原生交互与帧率实验").font(.system(size: 19, weight: .semibold))
                Spacer()
                Text("合成数据 · 独立预览").foregroundStyle(.secondary)
            }
            HStack {
                Button("事件压测（12 秒）") { state.measure("events") }
                Button("交互采样（12 秒）") { state.measure("interaction") }
                Button("静止采样（8 秒）") { state.measure("idle") }
                Button("减少动态（12 秒）") { state.measure("reduced") }
                Spacer()
            }.disabled(state.busy)
            HStack {
                Toggle("窄版", isOn: $state.compact)
                Toggle("浅色", isOn: $state.light)
                Toggle("减少动态效果", isOn: $state.reduced)
                Button("指针压测（12 秒）") { state.measure("pointer-stress") }
            }.toggleStyle(.checkbox).disabled(state.busy)
            WgLinkStage(phase: state.phase, monitor: state.monitor,
                        frozenReduceMotion: state.reduced,
                        frozenPointer: state.syntheticPointer,
                        onFrame: { date, cost in state.recorder.draw(at: date, cpu: cost) })
                .frame(width: state.compact ? 430 : 900)
                .environment(\.colorScheme, state.light ? .light : .dark)
            Text(state.report).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .textSelection(.enabled).frame(minHeight: 40, alignment: .topLeading)
            Text("采样记录实际 Canvas 重绘和 CPU 绘制耗时；呈现是否掉帧还需结合系统动画追踪。").font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(24).frame(width: 960, height: 680, alignment: .topLeading)
        .preferredColorScheme(.dark)
    }
}

@MainActor
private final class HUDLabDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
private struct HUDPerformanceLab {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = HUDLabDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "HUD 预览")
        let quit = NSMenuItem(title: "退出 HUD 预览", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = app
        applicationMenu.addItem(quit)
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        app.mainMenu = menu
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "WgHUDLab — 合成数据交互预览"
        window.contentView = NSHostingView(rootView: HUDLabView())
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        withExtendedLifetime(delegate) { app.run() }
    }
}
