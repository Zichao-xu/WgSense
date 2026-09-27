import AppKit
import SwiftUI

// 无极滚动图表（O-G01…O-G05）。
//
// 与“每秒追加一个点再补间动画”不同：样本按时间戳定位，每一帧以 (当前时间 − 延迟) 作为右边界，
// 曲线随时间连续左移；右端在相邻样本间插值，线头始终贴住右边缘平滑推进。
// 纵轴上限按帧指数逼近目标值，数据突变时坐标轴平滑伸缩而不是跳变。

/// 渲染期间需要跨帧保存的可变状态（放在引用类型里，Canvas 绘制闭包内可更新）。
private final class ChartRenderState {
    var scaleMax: Double = 1
    var lastFrame: TimeInterval = 0
}

struct PPStreamChart: View {
    struct Series {
        var name: LocalizedStringKey
        var color: Color
    }

    let title: LocalizedStringKey
    let buffer: PPSampleBuffer
    let series: [Series]
    let format: (Double) -> String
    var window: TimeInterval = 60
    /// 显示延迟：≥ 推送间隔（1s），保证右端总有两个样本可插值。
    var delay: TimeInterval = 1.1
    var floor: Double = 1

    @State private var paused = false
    @State private var hoverX: CGFloat?
    @State private var frozenAt: TimeInterval?
    @State private var windowVisible = true
    @State private var state = ChartRenderState()

    private var isFrozen: Bool { paused || hoverX != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(title).font(.system(size: 12, weight: .semibold))
                ForEach(Array(series.enumerated()), id: \.offset) { _, s in
                    HStack(spacing: 4) {
                        Capsule().fill(s.color).frame(width: 10, height: 3)
                        Text(s.name).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { togglePause() } label: {
                    Image(systemName: paused ? "play.fill" : "pause.fill").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(WgToolbarIconButtonStyle(isActive: paused))
                .help(paused ? "继续" : "暂停")
            }
            // 24fps：60s 时间窗铺满约 800pt，每帧位移约 0.55pt，已足够连续；
            // 异步渲染 + drawingGroup 把光栅化交给后台线程与 GPU（CPU 光栅化曾是最大开销）。
            TimelineView(.animation(minimumInterval: 1.0 / 24, paused: isFrozen || !windowVisible)) { timeline in
                Canvas(rendersAsynchronously: true) { context, size in
                    let now = frozenAt ?? timeline.date.timeIntervalSince1970
                    draw(context: &context, size: size, now: now)
                }
            }
            .drawingGroup()
            // 左边缘渐隐做成视图级遮罩：只合成一次，不再每帧开离屏图层。
            .mask {
                HStack(spacing: 0) {
                    Color.black.frame(width: 58)
                    LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12), .init(color: .black, location: 1)],
                                   startPoint: .leading, endPoint: .trailing)
                }
            }
            .frame(minHeight: 120)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    if hoverX == nil && !paused { frozenAt = Date().timeIntervalSince1970 }
                    hoverX = location.x
                case .ended:
                    hoverX = nil
                    if !paused { frozenAt = nil }
                }
            }
        }
        .background(PPWindowVisibility(visible: $windowVisible))
    }

    private func togglePause() {
        paused.toggle()
        frozenAt = paused ? Date().timeIntervalSince1970 : nil
    }

    // MARK: 绘制

    private func draw(context: inout GraphicsContext, size: CGSize, now: TimeInterval) {
        let labelWidth: CGFloat = 58
        let plot = CGRect(x: labelWidth, y: 6, width: max(1, size.width - labelWidth - 4), height: max(1, size.height - 12))
        let end = now - delay
        let start = end - window
        let samples = buffer.samples
        let visible = samples.filter { $0.time >= start - 2 && $0.time <= end + 2 }

        // 纵轴：目标 = 可见最大值 × 1.15；按帧指数逼近（约 0.35s 时间常数）。
        let visibleMax = visible.flatMap(\.values).max() ?? 0
        let target = max(floor, visibleMax * 1.15)
        let dt = state.lastFrame == 0 ? 1 : max(0, min(0.5, now - state.lastFrame))
        state.lastFrame = now
        state.scaleMax += (target - state.scaleMax) * (1 - exp(-dt / 0.35))
        if !state.scaleMax.isFinite || state.scaleMax <= 0 { state.scaleMax = target }
        let maxValue = state.scaleMax

        // 网格与刻度
        let grid = Color.primary.opacity(0.07)
        for i in 0...3 {
            let y = plot.maxY - plot.height * CGFloat(i) / 3
            var line = Path()
            line.move(to: CGPoint(x: plot.minX, y: y))
            line.addLine(to: CGPoint(x: plot.maxX, y: y))
            context.stroke(line, with: .color(grid), style: StrokeStyle(lineWidth: 1, dash: i == 0 ? [] : [3, 4]))
            if i > 0 {
                let text = Text(verbatim: format(maxValue * Double(i) / 3)).font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.secondary)
                context.draw(text, at: CGPoint(x: plot.minX - 6, y: y), anchor: .trailing)
            }
        }

        func x(_ t: TimeInterval) -> CGFloat { plot.minX + CGFloat((t - start) / window) * plot.width }
        func y(_ v: Double) -> CGFloat { plot.maxY - CGFloat(min(v, maxValue * 1.5) / maxValue) * plot.height }

        guard visible.count >= 1 else { return }
        context.clip(to: Path(plot))

        for (index, s) in series.enumerated() {
            var points = visible.map { CGPoint(x: x($0.time), y: y($0.values[safe: index] ?? 0)) }
            // 右端插值：线头落在右边界，随时间连续推进。
            if let v = value(at: end, series: index, in: visible) { points.append(CGPoint(x: plot.maxX, y: y(v))) }
            points = points.filter { $0.x <= plot.maxX + 0.5 }
            guard points.count >= 2 else { continue }
            let curve = smoothPath(points)
            var area = curve
            area.addLine(to: CGPoint(x: points.last!.x, y: plot.maxY))
            area.addLine(to: CGPoint(x: points.first!.x, y: plot.maxY))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [s.color.opacity(0.28), s.color.opacity(0.02)]),
                                                    startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
            context.stroke(curve, with: .color(s.color), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }

        // 悬停：竖线 + 数值
        if let hx = hoverX, hx >= plot.minX {
            let t = start + Double((hx - plot.minX) / plot.width) * window
            var line = Path()
            line.move(to: CGPoint(x: hx, y: plot.minY))
            line.addLine(to: CGPoint(x: hx, y: plot.maxY))
            context.stroke(line, with: .color(Color.primary.opacity(0.25)), lineWidth: 1)
            var lines: [String] = []
            for (index, _) in series.enumerated() {
                guard let v = value(at: t, series: index, in: visible) else { continue }
                context.fill(Path(ellipseIn: CGRect(x: hx - 3, y: y(v) - 3, width: 6, height: 6)), with: .color(series[index].color))
                lines.append(format(v))
            }
            let time = Date(timeIntervalSince1970: t).formatted(date: .omitted, time: .standard)
            let label = Text(verbatim: ([time] + lines).joined(separator: "  ")).font(.system(size: 10.5, weight: .medium).monospacedDigit())
            let resolved = context.resolve(label)
            let textSize = resolved.measure(in: CGSize(width: 400, height: 40))
            let boxX = min(max(plot.minX, hx + 8), plot.maxX - textSize.width - 12)
            let box = CGRect(x: boxX, y: plot.minY + 2, width: textSize.width + 12, height: textSize.height + 8)
            context.fill(Path(roundedRect: box, cornerRadius: 6), with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.92)))
            context.draw(resolved, at: CGPoint(x: box.midX, y: box.midY))
        }
    }

    /// 某时刻的线性插值值。
    private func value(at t: TimeInterval, series index: Int, in samples: [PPSampleBuffer.Sample]) -> Double? {
        guard let first = samples.first else { return nil }
        if t <= first.time { return first.values[safe: index] }
        for i in 1..<samples.count where samples[i].time >= t {
            let a = samples[i - 1], b = samples[i]
            let f = (t - a.time) / max(0.001, b.time - a.time)
            return (a.values[safe: index] ?? 0) * (1 - f) + (b.values[safe: index] ?? 0) * f
        }
        return samples.last?.values[safe: index]
    }

    /// Catmull-Rom → 三次贝塞尔，控制点纵向夹在相邻点之间，避免过冲到负值。
    private func smoothPath(_ p: [CGPoint]) -> Path {
        var path = Path()
        path.move(to: p[0])
        for i in 0..<(p.count - 1) {
            let p0 = p[max(0, i - 1)], p1 = p[i], p2 = p[i + 1], p3 = p[min(p.count - 1, i + 2)]
            let lo = min(p1.y, p2.y), hi = max(p1.y, p2.y)
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: min(hi, max(lo, p1.y + (p2.y - p0.y) / 6)))
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: min(hi, max(lo, p2.y - (p3.y - p1.y) / 6)))
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// 窗口是否真的可见（被遮挡、最小化、隐藏时为 false），用于暂停逐帧动画。
struct PPWindowVisibility: NSViewRepresentable {
    @Binding var visible: Bool

    final class Probe: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                self?.report()
            }
            report()
        }

        func report() {
            onChange?(window?.occlusionState.contains(.visible) ?? false)
        }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onChange = { value in
            DispatchQueue.main.async { if visible != value { visible = value } }
        }
        return probe
    }

    func updateNSView(_ nsView: Probe, context: Context) {}
}
