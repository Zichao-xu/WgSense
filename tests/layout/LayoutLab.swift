import AppKit
import Combine
import QuartzCore
import SwiftUI
import os.signpost

// Isolated experiment. No WgSense client, daemon, preferences, network or live data.
struct LabItem: Identifiable {
    let id: Int
    let title: String
    let note: String
    let spec: GridItemSpec
    let fixedHeight: CGFloat?
}

enum Fixture {
    static let tiles: [(String, String, Int, CGFloat)] = [
        ("VPN", "隧道已建立", 2, 80), ("接收", "可接收", 1, 80),
        ("发送", "无设备", 1, 80), ("代理", "运行中", 1, 80),
        ("配置", "默认配置", 1, 80), ("日志", "运行记录", 1, 80),
        ("关于", "版本信息", 1, 80), ("流量", "经由隧道", 2, 80),
        ("测速", "上次测量结果", 2, 168)
    ]
    static let paragraphs = [
        ("测法", "每一项都会影响测出来的数。改过的项标记出来，可单项恢复；每次测速会把当时的测法存进历史。"),
        ("采样间隔", "多久读一次计数；执行端不支持小数 sleep 时自动退到 1 秒。拖动改变宽度时，这段文字应当立即换行，下面的内容随之移动。"),
        ("真实 DNS", "绑网卡测速时解析测速域名；也用来判定「系统路由」实际走哪张网卡。"),
        ("公网选源", "每个候选源并行试跑，速度相加。比最快的源慢的淘汰；下行和上行分别保留入选源。"),
        ("上行线程", "一条连接推完指定的数据量后再重连。速率读取的是网卡计数，与测速工具自报的数字分别记录。")
    ]
    static func items(stress: Bool = false, mutation: Bool = false) -> [LabItem] {
        var result: [LabItem] = []
        for round in 0..<(stress ? 6 : 1) {
            for (i, tile) in tiles.enumerated() {
                result.append(LabItem(id: round * 100 + i, title: tile.0, note: tile.1,
                                      spec: GridItemSpec(span: tile.2, height: tile.3), fixedHeight: tile.3))
            }
        }
        for (i, p) in paragraphs.enumerated() {
            result.append(LabItem(id: 1000 + i, title: p.0,
                                  note: p.1 + (mutation ? " 内容已更新：字体或文案变化后，原有测量必须失效。" : ""),
                                  spec: GridItemSpec(span: 1, fullWidth: true), fixedHeight: nil))
        }
        return result
    }
}

@MainActor final class LiveReadings: ObservableObject {
    @Published var sequence = 0
    func tick() { sequence += 1 }
}

struct ReadingView: View {
    @ObservedObject var readings: LiveReadings
    var body: some View {
        Text("\(480 + (readings.sequence * 7) % 61) Mbps")
            .font(.system(size: 22, weight: .medium, design: .monospaced))
            .frame(width: 130, alignment: .leading)
            .accessibilityLabel("模拟速率，\(480 + (readings.sequence * 7) % 61) 兆比特每秒")
    }
}

@MainActor enum GeometryCapture {
    static var active = false
    static var rects: [Int: CGRect] = [:]
}

struct LabCell: View {
    let item: LabItem
    var fontSize: CGFloat
    var readings: LiveReadings
    @State private var selected = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { selected.toggle() } label: {
                HStack {
                    Text(item.title).font(.system(size: fontSize, weight: .semibold))
                    if selected { Image(systemName: "checkmark") }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            if item.title == "测速" { ReadingView(readings: readings) }
            Text(item.note).font(.system(size: fontSize - 1))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if item.fixedHeight != nil { Spacer(minLength: 0) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: item.fixedHeight, alignment: .topLeading)
        .background {
            // Layout image comparisons use a SwiftUI canvas: ImageRenderer does not
            // render NSViewRepresentable. Native plate appearance is checked in-app.
            Canvas { ctx, size in
                let path = ChamferShape(12).path(in: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5))
                ctx.fill(path, with: .color(.white.opacity(selected ? 0.14 : 0.055)))
                ctx.stroke(path, with: .color(.white.opacity(0.12)), lineWidth: 1)
            }
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("lab")) } action: { rect in
            if GeometryCapture.active { GeometryCapture.rects[item.id] = rect }
        }
    }
}

struct LabPage: View {
    var optimized: Bool
    var items: [LabItem]
    var fontSize: CGFloat = 13
    var readings: LiveReadings
    var body: some View {
        Group {
            RetainedGrid(specs: items.map(\.spec)) {
                ForEach(items) { LabCell(item: $0, fontSize: fontSize, readings: readings) }
            }
        }.coordinateSpace(name: "lab")
    }

    func reference(width: CGFloat) -> some View {
        let columns = GridGeometry.columns(width)
        let rows = GridGeometry.pack(items.map(\.spec), columns: columns)
        let cell = (width - CGFloat(columns - 1) * GridGeometry.gap) / CGFloat(columns)
        return VStack(alignment: .leading, spacing: GridGeometry.gap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: GridGeometry.gap) {
                    ForEach(Array(zip(row.indices, row.spans)), id: \.0) { index, span in
                        LabCell(item: items[index], fontSize: fontSize, readings: readings)
                            .frame(width: cell * CGFloat(span) + GridGeometry.gap * CGFloat(span - 1))
                    }
                }
            }
        }.coordinateSpace(name: "lab")
    }
}

@MainActor final class WidthState: ObservableObject {
    @Published var width: CGFloat = 360
    @Published var optimized = true
    @Published var visibleOnly = false
    @Published var stress = false
    @Published var mutated = false
    @Published var largeFont = false
    @Published var status = "可拖动宽度滑块；文字与磁贴均为真实视图。"
    let readings = LiveReadings()
    var fontSize: CGFloat { largeFont ? 17 : 13 }
}

struct TestCanvas: View {
    @ObservedObject var state: WidthState
    var body: some View {
        let items = Fixture.items(stress: state.stress, mutation: state.mutated)
        let page = LabPage(optimized: state.optimized, items: items, fontSize: state.fontSize, readings: state.readings)
        if state.visibleOnly {
            VisibleNativePage(items: items, width: state.width, fontSize: state.fontSize, readings: state.readings)
                .frame(width: state.width + 24).frame(maxWidth: .infinity, alignment: .leading)
        } else { ScrollView {
            Group {
                if state.optimized { page }
                else { page.reference(width: state.width) }
            }
            .animation(.smooth(duration: 0.3), value: GridGeometry.columns(state.width))
            .frame(width: state.width, alignment: .topLeading)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        } }
    }
}

struct LabControls: View {
    @ObservedObject var state: WidthState
    let run: () -> Void
    @State private var pastedText = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("实时排版实验").font(.system(size: 25, weight: .bold))
            Text("模拟数据 · 独立窗口").foregroundStyle(.secondary)
            Picker("布局", selection: $state.optimized) {
                Text("保留视图身份").tag(true)
                Text("原有行容器").tag(false)
            }.pickerStyle(.radioGroup).disabled(state.visibleOnly)
            Toggle("按可视区挂载", isOn: $state.visibleOnly)
            Text("内容宽度：\(Int(state.width)) 点")
            Slider(value: $state.width, in: 176...620).accessibilityLabel("内容宽度")
            Toggle("长页面压力场景", isOn: $state.stress)
            Toggle("增加说明文字", isOn: $state.mutated)
            Toggle("放大文字", isOn: $state.largeFont)
            Button("运行三种布局对照", action: run)
            TextField("粘贴刚复制的正文以检查", text: $pastedText)
                .textFieldStyle(.roundedBorder).accessibilityLabel("复制检查")
            Text(state.status).font(.system(size: 12)).foregroundStyle(.secondary).textSelection(.enabled)
            Spacer()
            Text("点磁贴标题可选中。跨列后检查勾选是否保留；正文可选择、复制。数字持续模拟更新。").font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(20).frame(width: 270)
    }
}

struct IntervalStats: Codable {
    let samples: Int
    let p50: Double
    let p95: Double
    let p99: Double
    let max: Double
    init(_ values: [Double]) {
        let sorted = values.sorted(); samples = sorted.count
        func percentile(_ q: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * q))] }
        p50 = percentile(0.5); p95 = percentile(0.95); p99 = percentile(0.99); max = sorted.last ?? 0
    }
}

@MainActor final class LabRunner: NSObject, NSApplicationDelegate {
    let state = WidthState()
    var window: NSWindow!
    var canvas: NSHostingView<TestCanvas>!
    private var link: CADisplayLink?
    private var readingTimer: Timer?
    private var began: CFTimeInterval = 0
    private var last: CFTimeInterval = 0
    private var intervals: [Double] = []
    private var updateCPU: [Double] = []
    private var results: [[String: Any]] = []
    private var phase = 0
    private var startReadings = 0
    private var traceID = OSSignpostID.invalid
    private let traceLog = OSLog(subsystem: "local.wgsense.layoutlab", category: .pointsOfInterest)

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        sender.activate(ignoringOtherApps: true)
        return true
    }

    func show() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 850))
        window = NSWindow(contentRect: root.bounds, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "WgSense 排版实验（模拟数据）"
        window.contentView = root
        window.minSize = NSSize(width: 980, height: 600)
        let controls = NSHostingView(rootView: LabControls(state: state, run: { [weak self] in self?.run() }))
        controls.frame = NSRect(x: 0, y: 0, width: 270, height: 850)
        controls.autoresizingMask = [.height]
        root.addSubview(controls)
        canvas = NSHostingView(rootView: TestCanvas(state: state))
        canvas.frame = NSRect(x: 280, y: 0, width: 720, height: 850)
        canvas.autoresizingMask = [.width, .height]
        root.addSubview(canvas)
        window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        readingTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.state.readings.tick() }
        }
        RunLoop.main.add(readingTimer!, forMode: .common)
        if Bundle.main.object(forInfoDictionaryKey: "LayoutLabAutostart") as? Bool == true {
            state.status = "10 秒后自动运行 6 项对照，随后可手动检查。"
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.run() }
        }
    }

    func run() {
        guard link == nil else { return }
        results = []; phase = 0
        next()
    }

    private func next() {
        guard phase < 6 else { finish(); return }
        state.optimized = phase % 3 != 0
        state.visibleOnly = phase % 3 == 2
        state.stress = phase >= 3
        state.mutated = false; state.largeFont = false
        state.status = "对照 \(phase + 1)/6：\(state.visibleOnly ? "可视区挂载" : state.optimized ? "保留身份" : "原有行容器") · \(state.stress ? "长页面" : "常规页面")"
        began = CACurrentMediaTime() + 1.5; last = 0
        intervals = []; updateCPU = []; startReadings = state.readings.sequence
        traceID = OSSignpostID(log: traceLog)
        os_signpost(.begin, log: traceLog, name: "Layout Scenario", signpostID: traceID,
                    "phase=%{public}d", phase)
        let link = canvas.displayLink(target: self, selector: #selector(tick(_:)))
        let maximum = Float(min(120, window.screen?.maximumFramesPerSecond ?? 60))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: maximum, maximum: maximum, preferred: maximum)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func tick(_ sender: CADisplayLink) {
        let now = CACurrentMediaTime()
        let elapsed = now - began
        // Include both edges and both directions; no pause at a wrapping threshold.
        let unit = (max(0, elapsed) / 2).truncatingRemainder(dividingBy: 2)
        let width = 176 + 444 * (unit <= 1 ? unit : 2 - unit)
        if elapsed >= 0, last > 0 { intervals.append((now - last) * 1000) }
        last = elapsed >= 0 ? now : 0
        let start = CACurrentMediaTime()
        os_signpost(.begin, log: traceLog, name: "Layout Width Update")
        state.width = width
        canvas.layoutSubtreeIfNeeded()
        CATransaction.flush()
        os_signpost(.end, log: traceLog, name: "Layout Width Update")
        if elapsed >= 0 { updateCPU.append((CACurrentMediaTime() - start) * 1000) }
        if elapsed >= 8 {
            os_signpost(.end, log: traceLog, name: "Layout Scenario", signpostID: traceID)
            sender.invalidate(); link = nil
            let cpu = IntervalStats(updateCPU), cadence = IntervalStats(intervals)
            func dict(_ stats: IntervalStats) -> Any { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(stats))) ?? [:] }
            results.append([
                "mode": state.visibleOnly ? "visible-native" : state.optimized ? "retained" : "row-containers", "stress": state.stress,
                "itemCount": Fixture.items(stress: state.stress).count,
                "widthUpdateCPUms": dict(cpu), "callbackArrivalIntervalsMs": dict(cadence),
                "readingsAdvanced": state.readings.sequence - startReadings,
                "screen": window.screen?.localizedName ?? "unknown",
                "screenMaximumHz": window.screen?.maximumFramesPerSecond ?? 0,
                "windowVisible": window.isVisible,
                "windowOcclusionVisible": window.occlusionState.contains(.visible),
                "scope": "Synthetic native SwiftUI page. Width-update CPU includes explicit layout/transaction flush, not all deferred work or compositor presentation. Callback arrivals are scheduling evidence, not presented fps."
            ])
            phase += 1; next()
        }
    }

    private func finish() {
        let path = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("benchmark.json")
        let report: [String: Any] = ["results": results, "timestamp": ISO8601DateFormatter().string(from: Date()),
                                     "productionIntegrated": false, "networkUsed": false]
        do {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: path)
            state.status = "6 项对照完成，数据已保存。可继续拖动，检查换行与勾选状态。"
        } catch { state.status = "保存失败：\(error.localizedDescription)" }
    }
}

@main enum LayoutLabMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.appearance = NSAppearance(named: .darkAqua)
        if CommandLine.arguments.contains("--verify") {
            do { try verify(); exit(0) } catch { print("FAIL: \(error)"); exit(1) }
        }
        if CommandLine.arguments.contains("--render") {
            do { try render(); exit(0) } catch { print("FAIL: \(error)"); exit(1) }
        }
        let runner = LabRunner()
        app.delegate = runner
        let menu = NSMenu()
        let item = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "退出排版实验", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.submenu = appMenu; menu.addItem(item); app.mainMenu = menu
        runner.show()
        withExtendedLifetime(runner) { app.run() }
    }

    @MainActor static func render() throws {
        let path = CommandLine.arguments.last!
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let readings = LiveReadings()
        readings.sequence = 12
        for width: CGFloat in [231.5, 232, 352, 620] {
            for optimized in [false, true] {
                let page = LabPage(optimized: optimized, items: Fixture.items(), readings: readings)
                let content: AnyView = optimized ? AnyView(page) : AnyView(page.reference(width: width))
                let renderer = ImageRenderer(content: content.frame(width: width).padding(12)
                    .background(Color(red: 0.075, green: 0.08, blue: 0.09)).environment(\.colorScheme, .dark))
                renderer.scale = 2
                guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                    throw NSError(domain: "LayoutLabRender", code: 1)
                }
                let name = "\(optimized ? "retained" : "reference")-\(width).png"
                try png.write(to: URL(fileURLWithPath: path).appendingPathComponent(name))
            }
        }
        print("Rendered 8 native SwiftUI layout images")
    }

    @MainActor static func verify() throws {
        let readings = LiveReadings()
        var cases = 0, comparisons = 0
        var failures: [String] = []
        // Full backing-pixel sweep at 1x and 2x; compare against independent row packing.
        for stress in [false, true] {
            let items = Fixture.items(stress: stress)
            for pixel in 352...1240 {
                let width = CGFloat(pixel) / 2
                let columns = max(1, Int((width + 8) / 120))
                let cell = (width - CGFloat(columns - 1) * 8) / CGFloat(columns)
                var oracle: [Int: CGRect] = [:]
                var row: [(Int, Int)] = [], used = 0, y: CGFloat = 0
                func height(_ i: Int, _ w: CGFloat) -> CGFloat { items[i].fixedHeight ?? (ceil(CGFloat(items[i].note.utf16.count) * 6 / max(1, w - 24)) * 16 + 50) }
                func flush() {
                    var x: CGFloat = 0, h: CGFloat = 0
                    for (i, span) in row {
                        let w = cell * CGFloat(span) + CGFloat(span - 1) * 8
                        oracle[i] = CGRect(x: x, y: y, width: w, height: height(i, w))
                        h = max(h, height(i, w)); x += w + 8
                    }
                    y += h + 8; row = []; used = 0
                }
                for (i, item) in items.enumerated() {
                    let span = item.spec.fullWidth ? columns : min(columns, item.spec.span)
                    if used + span > columns, !row.isEmpty { flush() }
                    row.append((i, span)); used += span
                    if used == columns { flush() }
                }
                if !row.isEmpty { flush() }
                let candidate = GridGeometry.frames(width: width, rows: GridGeometry.pack(items.map(\.spec), columns: columns), measure: height)
                cases += 1; comparisons += items.count
                if candidate != oracle { failures.append("geometry \(stress) \(width)") }
            }
        }
        // Real SwiftUI measurement comparison: new widths, repeats, reversals, fonts and text mutations.
        // Tests host layout, not a font-width approximation or a screenshot.
        let widths: [CGFloat] = [176, 176.5, 231.5, 232, 232.5, 351.5, 352, 352.5, 471.5, 472, 472.5, 591.5, 592, 592.5, 620, 352, 176]
        var nativeCases = 0
        var visibleCases = 0
        var visibleFrameComparisons = 0
        var maxMounted = 0
        var reachabilityChecks = 0
        var retainedIdentityChecks = 0
        let native = VisibleNativePage.Coordinator()
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 644, height: 650))
        let document = VisibleNativePage.FlippedDocument()
        scroll.documentView = document
        native.attach(scroll, document: document)
        for mutation in [false, true] {
            for font: CGFloat in [13, 17] {
                let items = Fixture.items(mutation: mutation)
                let page = LabPage(optimized: true, items: items, fontSize: font, readings: readings)
                let retained = NSHostingController(rootView: AnyView(page.fixedSize(horizontal: false, vertical: true)))
                for width in widths {
                    let reference = NSHostingController(rootView: AnyView(page.reference(width: width).fixedSize(horizontal: false, vertical: true)))
                    let expected = reference.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
                    let actual = retained.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
                    native.update(items: items, width: width, fontSize: font, readings: readings)
                    let visibleHeight = (native.geometryForVerification.values.map(\.maxY).max() ?? 12) - 12
                    visibleCases += 1
                    visibleFrameComparisons += native.geometryForVerification.count
                    maxMounted = max(maxMounted, native.mountedCount)
                    if abs(visibleHeight - expected.height) > 0.51 {
                        failures.append("visible-native \(width), font \(font), mutation \(mutation): \(visibleHeight) != \(expected.height)")
                    }
                    nativeCases += 1
                    if abs(actual.height - expected.height) > 0.51 || abs(actual.width - expected.width) > 0.51 {
                        failures.append("native \(width), font \(font), mutation \(mutation): \(actual) != \(expected)")
                    }
                }
            }
        }
        // Every item must be reachable after scroll/reflow, with the same retained host.
        for stress in [false, true] {
            let items = Fixture.items(stress: stress)
            for width: CGFloat in [176, 620, 352, 176] {
                native.update(items: items, width: width, fontSize: 13, readings: readings)
                let identities = native.controllerIdentities
                for item in items {
                    let frame = native.geometryForVerification[item.id]!
                    let y = min(max(0, frame.minY), max(0, document.frame.height - scroll.contentView.bounds.height))
                    scroll.contentView.setBoundsOrigin(CGPoint(x: 0, y: y))
                    native.mountVisible()
                    reachabilityChecks += 1
                    if !native.mountedIDs.contains(item.id) { failures.append("unreachable \(item.id) at \(width)") }
                }
                retainedIdentityChecks += items.count
                if identities != native.controllerIdentities { failures.append("host identity changed on scroll at \(width)") }
            }
        }
        let report: [String: Any] = ["geometryWidthCases": cases, "itemFrameComparisons": comparisons,
                                     "nativeSwiftUIMeasurementCases": nativeCases,
                                     "visibleNativeMeasurementCases": visibleCases, "visibleNativeFrameCount": visibleFrameComparisons,
                                     "maximumMountedInNativeMeasurementTests": maxMounted, "failures": failures,
                                     "visibilityReachabilityChecks": reachabilityChecks,
                                     "retainedIdentityChecks": retainedIdentityChecks,
                                     "scope": "Geometry sweep uses deterministic synthetic heights; native comparison uses actual selectable SwiftUI Text and real sizeThatFits at threshold-adjacent widths. Does not prove production or compositor performance."]
        let path = CommandLine.arguments.last ?? "/tmp/layout-verification.json"
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        print("geometry \(cases), frames \(comparisons), native \(nativeCases), failures \(failures.count)")
        if !failures.isEmpty {
            print(failures.prefix(8).joined(separator: "\n"))
            throw NSError(domain: "LayoutLab", code: 1)
        }
    }
}
