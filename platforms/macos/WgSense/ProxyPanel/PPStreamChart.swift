import AppKit
import QuartzCore
import SwiftUI

// 无极滚动图表（O-G01…O-G05）。
//
// 样本按时间戳定位，右边界 = 当前时间 − 延迟，曲线随时间连续左移，线头贴住右边缘推进。
//
// 连续运动完全交给 Core Animation：
//   · 曲线画成比视窗略宽的一条“纸带”（CAShapeLayer），每来一个样本（1Hz）重建一次路径；
//   · 纸带的平移是一段匀速的 position 动画，由系统渲染服务器逐帧执行，App 进程逐帧零开销；
//   · 右缘“记录笔”的纵向运动是按样本插值的关键帧动画；
//   · 纵轴上限变化时，纸带在纵向做一次缓动缩放过渡，不跳变。
// 之前用 TimelineView 逐帧求值/栅格化，三张图 24–60fps 占掉 10–15% CPU。

struct PPStreamChart: View {
    struct Series {
        var name: LocalizedStringKey
        var color: Color
        /// 是否铺面积（主系列铺，次系列只描线，避免两层半透明叠成一团）。
        var fill = true
        /// 虚线描边：单色体系里区分次系列的方式。
        var dashed = false
    }

    let title: LocalizedStringKey
    @ObservedObject var buffer: PPSampleBuffer
    let series: [Series]
    let format: (Double) -> String
    var window: TimeInterval = 60
    /// 显示延迟：≥ 推送间隔（1s），保证右端总有样本可衔接。
    var delay: TimeInterval = 1.2
    var floor: Double = 1

    @State private var paused = false
    @State private var hoverX: CGFloat?
    @State private var frozenAt: TimeInterval?

    static let gutter: CGFloat = 68     // 左侧纵轴刻度
    static let ruler: CGFloat = 16      // 底部时间尺
    /// 纸带比视窗多出的时长：左侧留出渐隐余量。
    static let tail: TimeInterval = 4

    init(title: LocalizedStringKey, buffer: PPSampleBuffer, series: [Series], format: @escaping (Double) -> String,
         window: TimeInterval = 60, floor: Double = 1) {
        self.title = title
        self.buffer = buffer
        self.series = series
        self.format = format
        self.window = window
        self.floor = floor
    }

    var body: some View {
        let samples = buffer.samples
        let scale = scale(for: samples)
        VStack(alignment: .leading, spacing: 8) {
            header(values: samples.last?.values ?? [])
            GeometryReader { geo in
                let plot = CGRect(x: Self.gutter, y: 4, width: max(1, geo.size.width - Self.gutter - 2),
                                  height: max(1, geo.size.height - Self.ruler - 6))
                ZStack(alignment: .topLeading) {
                    PPChartAxis(scale: scale, format: format, window: window, size: geo.size, plot: plot)
                        .equatable()
                    PPChartTape(samples: samples, version: buffer.version, scale: scale, series: series,
                                plot: plot, window: window, delay: delay, frozenAt: frozenAt)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .allowsHitTesting(false)
                    if let hx = hoverX, hx >= plot.minX, let at = frozenAt {
                        hoverLayer(hx: hx, now: at, scale: scale, plot: plot, samples: samples)
                    }
                }
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
            .frame(minHeight: 110)
        }
    }

    // MARK: 标题行：图例 + 当前读数

    private func header(values: [Double]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(WgInk.ink)
            ForEach(Array(series.enumerated()), id: \.offset) { index, s in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Path { p in p.move(to: CGPoint(x: 0, y: 1)); p.addLine(to: CGPoint(x: 12, y: 1)) }
                        .stroke(s.color, style: StrokeStyle(lineWidth: 1.5, dash: s.dashed ? [3, 2] : []))
                        .frame(width: 12, height: 2)
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
                    if series.count > 1 {
                        Text(s.name).font(.system(size: 11)).foregroundStyle(WgInk.ink3)
                    }
                    WgReadout(text: values[safe: index].map(format) ?? "—", size: 12.5, weight: .medium)
                }
            }
            Spacer()
            Button { togglePause() } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill").font(.system(size: 8.5, weight: .bold))
            }
            .buttonStyle(WgToolbarIconButtonStyle(isActive: paused))
            .help(paused ? "继续" : "暂停")
        }
    }

    private func togglePause() {
        paused.toggle()
        frozenAt = paused ? Date().timeIntervalSince1970 : nil
    }

    /// 纵轴上限 = 视窗内最大值 × 1.15，再取整。
    private func scale(for samples: [PPSampleBuffer.Sample]) -> Double {
        let start = (frozenAt ?? Date().timeIntervalSince1970) - delay - window - 2
        var visibleMax = 0.0
        for sample in samples.reversed() {
            if sample.time < start { break }
            for v in sample.values where v > visibleMax { visibleMax = v }
        }
        return nice(max(floor, visibleMax * 1.15))
    }

    /// 上限取整，使四等分刻度都是整数读数。字节类数据先按 1024 进位换算到显示单位再取整，
    /// 否则 100000 B 这种“十进制整数”显示出来是 97.7 KB。
    private func nice(_ v: Double) -> Double {
        var unit = 1.0
        while v / unit >= 1024 && unit < pow(1024, 4) { unit *= 1024 }
        let x = v / unit
        let exp = pow(10, Foundation.floor(log10(x)))
        for m in [1.0, 1.2, 1.6, 2, 2.4, 3.2, 4, 6, 8, 10] where m * exp >= x { return m * exp * unit }
        return 10 * exp * unit
    }

    // MARK: 悬停

    private func hoverLayer(hx: CGFloat, now: TimeInterval, scale: Double, plot: CGRect, samples: [PPSampleBuffer.Sample]) -> some View {
        let end = now - delay
        let t = end - window + Double((hx - plot.minX) / plot.width) * window
        let values: [(Int, Double)] = series.indices.compactMap { i in Self.value(at: t, series: i, in: samples).map { (i, $0) } }
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(WgInk.ink3).frame(width: 1, height: plot.height)
                .position(x: hx, y: plot.midY)
            ForEach(values, id: \.0) { i, v in
                Circle().fill(series[i].color).frame(width: 6, height: 6)
                    .position(x: hx, y: plot.maxY - CGFloat(min(v, scale * 1.5) / scale) * plot.height)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: Date(timeIntervalSince1970: t).formatted(date: .omitted, time: .standard))
                    .font(WgInk.mono(9.5)).foregroundStyle(WgInk.ink3)
                ForEach(values, id: \.0) { i, v in
                    HStack(spacing: 6) {
                        Rectangle().fill(series[i].color).frame(width: 8, height: 2)
                        Text(series[i].name).font(.system(size: 10.5)).foregroundStyle(WgInk.ink2)
                        Spacer(minLength: 8)
                        Text(verbatim: format(v)).font(WgInk.figure(10.5))
                    }
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .frame(width: 168)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(WgInk.rule))
            .offset(x: hx + 176 > plot.maxX ? hx - 176 : hx + 8, y: plot.minY + 2)
        }
        .allowsHitTesting(false)
    }

    /// 某时刻的线性插值值。
    static func value(at t: TimeInterval, series index: Int, in samples: [PPSampleBuffer.Sample]) -> Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if t <= first.time { return first.values[safe: index] }
        if t >= last.time { return last.values[safe: index] }
        var lo = 0, hi = samples.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if samples[mid].time < t { lo = mid } else { hi = mid }
        }
        let a = samples[lo], b = samples[hi]
        let f = (t - a.time) / max(0.001, b.time - a.time)
        return (a.values[safe: index] ?? 0) * (1 - f) + (b.values[safe: index] ?? 0) * f
    }
}

// MARK: - 坐标层：横向刻度线 + 纵轴读数 + 底部时间尺

private struct PPChartAxis: View, Equatable {
    let scale: Double
    let format: (Double) -> String
    let window: TimeInterval
    let size: CGSize
    let plot: CGRect

    static func == (a: Self, b: Self) -> Bool { a.scale == b.scale && a.size == b.size && a.window == b.window }

    var body: some View {
        Canvas { context, _ in
            let rule = Color.primary.opacity(0.07)
            for i in 0...4 {
                let y = plot.maxY - plot.height * CGFloat(i) / 4
                var line = Path()
                line.move(to: CGPoint(x: plot.minX, y: y))
                line.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(line, with: .color(i == 0 ? Color.primary.opacity(0.2) : rule), lineWidth: i == 0 ? 1 : 0.5)
                // 左端短刻度，像直尺的刻痕。
                var tick = Path()
                tick.move(to: CGPoint(x: plot.minX - 4, y: y))
                tick.addLine(to: CGPoint(x: plot.minX, y: y))
                context.stroke(tick, with: .color(Color.primary.opacity(0.28)), lineWidth: 1)
                if i > 0, i % 2 == 0 || plot.height > 120 {
                    let label = format(scale * Double(i) / 4)
                        .replacingOccurrences(of: ".00 ", with: " ")
                        .replacingOccurrences(of: ".0 ", with: " ")
                    context.draw(Text(verbatim: label).font(WgInk.mono(9)).foregroundStyle(Color.primary.opacity(0.42)),
                                 at: CGPoint(x: plot.minX - 8, y: y), anchor: .trailing)
                }
            }
            // 时间尺：每 5s 一个细刻痕，每 15s 一个长刻痕 + 读数（相对“现在”）。
            let base = plot.maxY
            for s in stride(from: 0, through: Int(window), by: 5) {
                let x = plot.maxX - CGFloat(Double(s) / window) * plot.width
                let major = s % 15 == 0
                var tick = Path()
                tick.move(to: CGPoint(x: x, y: base))
                tick.addLine(to: CGPoint(x: x, y: base + (major ? 5 : 3)))
                context.stroke(tick, with: .color(Color.primary.opacity(major ? 0.32 : 0.18)), lineWidth: 1)
                if major {
                    let label = s == 0 ? "NOW" : "−\(s)s"
                    context.draw(Text(verbatim: label).font(WgInk.mono(8.5)).foregroundStyle(Color.primary.opacity(0.4)),
                                 at: CGPoint(x: x, y: base + 7), anchor: s == 0 ? .topTrailing : .top)
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}

// MARK: - 纸带（Core Animation）

private struct PPChartTape: NSViewRepresentable {
    let samples: [PPSampleBuffer.Sample]
    let version: TimeInterval
    let scale: Double
    let series: [PPStreamChart.Series]
    let plot: CGRect
    let window: TimeInterval
    let delay: TimeInterval
    let frozenAt: TimeInterval?

    func makeNSView(context: Context) -> TapeView { TapeView() }

    func updateNSView(_ view: TapeView, context: Context) {
        view.update(TapeView.Input(samples: samples, version: version, scale: scale,
                                   series: series.map { .init(color: NSColor($0.color), fill: $0.fill, dashed: $0.dashed) },
                                   plot: plot, window: window, delay: delay, frozenAt: frozenAt))
    }
}

final class TapeView: NSView {
    struct SeriesStyle { var color: NSColor; var fill: Bool; var dashed: Bool }
    struct Input {
        var samples: [PPSampleBuffer.Sample]
        var version: TimeInterval
        var scale: Double
        var series: [SeriesStyle]
        var plot: CGRect
        var window: TimeInterval
        var delay: TimeInterval
        var frozenAt: TimeInterval?
    }

    private let clip = CALayer()        // 视窗：裁剪 + 左缘渐隐
    private let fade = CAGradientLayer()
    private let scaler = CALayer()      // 纵轴缩放过渡
    private let tape = CALayer()        // 平移的纸带
    private var fills: [CAGradientLayer] = []
    private var fillMasks: [CAShapeLayer] = []
    private var strokes: [CAShapeLayer] = []
    private var pens: [CAShapeLayer] = []
    private var last: Input?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // 图层宿主视图：图层树完全自己管理，坐标原点在左上。
        layer = CALayer()
        wantsLayer = true
        layer?.isGeometryFlipped = true
        clip.masksToBounds = true
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
        fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor]
        fade.locations = [0, 0.1, 1]
        clip.mask = fade
        scaler.anchorPoint = CGPoint(x: 0.5, y: 1)
        tape.anchorPoint = .zero
        layer?.addSublayer(clip)
        clip.addSublayer(scaler)
        scaler.addSublayer(tape)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// AppKit 可能在挂载/布局时重设根图层几何，每次更新前确认原点在左上。
    private func ensureFlipped() {
        if layer?.isGeometryFlipped != true { layer?.isGeometryFlipped = true }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let last { self.last = nil; update(last) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 离开窗口时动画会被移除；回到窗口重新挂上。
        if window != nil, let last { self.last = nil; update(last) }
    }

    func update(_ input: Input) {
        let previous = last
        last = input
        guard let latest = input.samples.last?.time, input.plot.width > 1 else {
            last = nil   // 尚未布局：下一次有数据时按“首次”完整布局
            CATransaction.begin(); CATransaction.setDisableActions(true)
            strokes.forEach { $0.path = nil }; fillMasks.forEach { $0.path = nil }; pens.forEach { $0.isHidden = true }
            CATransaction.commit()
            return
        }
        let plot = input.plot
        let pps = plot.width / input.window
        let span = input.window + PPStreamChart.tail
        let geometryChanged = previous?.plot != plot || previous?.window != input.window
        let dataChanged = geometryChanged || previous?.version != input.version || previous?.scale != input.scale
            || previous?.series.count != input.series.count
        let freezeChanged = (previous?.frozenAt == nil) != (input.frozenAt == nil) || previous?.frozenAt != input.frozenAt
        guard dataChanged || freezeChanged || previous == nil else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ensureFlipped()
        ensureLayers(count: input.series.count)

        if geometryChanged {
            clip.frame = plot
            fade.frame = CGRect(origin: .zero, size: plot.size)
            scaler.bounds = CGRect(origin: .zero, size: plot.size)
            scaler.position = CGPoint(x: plot.width / 2, y: plot.height)
        }

        if dataChanged {
            tape.bounds = CGRect(x: 0, y: 0, width: CGFloat(span) * pps, height: plot.height)
            buildPaths(input, latest: latest, span: span, pps: pps)
            // 纵轴缩放过渡：新路径按新上限画，先把纸带纵向压/拉回旧比例，再缓动到 1。
            if let old = previous?.scale, old > 0, old != input.scale, !geometryChanged {
                let anim = CABasicAnimation(keyPath: "transform.scale.y")
                anim.fromValue = input.scale / old
                anim.toValue = 1
                anim.duration = 0.55
                anim.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
                scaler.add(anim, forKey: "rescale")
            }
        }

        // 平移：x(t) = (latest − t + delay − tail) × pps，匀速。
        let now = input.frozenAt ?? Date().timeIntervalSince1970
        func x(_ t: TimeInterval) -> CGFloat { CGFloat(latest - t + input.delay - PPStreamChart.tail) * pps }
        tape.removeAnimation(forKey: "scroll")
        if input.frozenAt == nil {
            let duration: TimeInterval = 30
            tape.position = CGPoint(x: x(now + duration), y: 0)
            let scroll = CABasicAnimation(keyPath: "position.x")
            scroll.fromValue = x(now)
            scroll.toValue = x(now + duration)
            scroll.duration = duration
            scroll.timingFunction = CAMediaTimingFunction(name: .linear)
            tape.add(scroll, forKey: "scroll")
        } else {
            tape.position = CGPoint(x: x(now), y: 0)
        }

        updatePens(input, now: now)
        CATransaction.commit()
    }

    private func ensureLayers(count: Int) {
        while strokes.count < count {
            let fill = CAGradientLayer()
            let mask = CAShapeLayer()
            fill.anchorPoint = .zero
            fill.mask = mask
            let stroke = CAShapeLayer()
            stroke.fillColor = nil
            stroke.lineCap = .round
            stroke.lineJoin = .round
            let pen = CAShapeLayer()
            pen.path = CGPath(ellipseIn: CGRect(x: -2.5, y: -2.5, width: 5, height: 5), transform: nil)
            pen.lineWidth = 1.5
            // 次系列先画、主系列在上：后创建的是主系列，放在最上层。
            tape.addSublayer(fill)
            tape.addSublayer(stroke)
            layer?.addSublayer(pen)
            fills.append(fill); fillMasks.append(mask); strokes.append(stroke); pens.append(pen)
        }
    }

    private func resolved(_ color: NSColor, alpha: CGFloat = 1) -> CGColor {
        var cg: CGColor = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let base = color.usingColorSpace(.sRGB) ?? color
            cg = base.withAlphaComponent(base.alphaComponent * alpha).cgColor
        }
        return cg
    }

    /// 45° 剖面线图案（6pt 间距），颜色按当前外观解析。
    private func hatchColor(_ color: NSColor) -> CGColor {
        let tile = NSImage(size: NSSize(width: 6, height: 6), flipped: false) { [weak self] rect in
            guard let self else { return false }
            var c = color
            self.effectiveAppearance.performAsCurrentDrawingAppearance { c = (color.usingColorSpace(.sRGB) ?? color).withAlphaComponent(0.34) }
            c.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1
            path.move(to: NSPoint(x: -1, y: -1)); path.line(to: NSPoint(x: 7, y: 7))
            path.move(to: NSPoint(x: -1, y: 5)); path.line(to: NSPoint(x: 1, y: 7))
            path.move(to: NSPoint(x: 5, y: -1)); path.line(to: NSPoint(x: 7, y: 1))
            path.stroke()
            return true
        }
        return NSColor(patternImage: tile).cgColor
    }

    private func buildPaths(_ input: Input, latest: TimeInterval, span: TimeInterval, pps: CGFloat) {
        let h = input.plot.height
        let start = latest - span
        let visible = input.samples.filter { $0.time >= start - 2 }
        let scale = input.scale
        func pt(_ s: PPSampleBuffer.Sample, _ i: Int) -> CGPoint {
            CGPoint(x: CGFloat(s.time - start) * pps, y: h - CGFloat(min(s.values[safe: i] ?? 0, scale * 1.5) / scale) * h)
        }
        let background = resolved(NSColor.windowBackgroundColor)
        for (i, style) in input.series.enumerated() {
            let points = visible.map { pt($0, i) }
            let stroke = strokes[i], fill = fills[i], mask = fillMasks[i]
            stroke.strokeColor = resolved(style.color)
            stroke.lineWidth = style.fill ? 1.5 : 1.2
            stroke.lineDashPattern = style.dashed ? [3, 2.5] : nil
            pens[i].fillColor = resolved(style.color)
            pens[i].strokeColor = background
            guard points.count >= 2 else { stroke.path = nil; mask.path = nil; continue }
            let curve = Self.smoothPath(points)
            stroke.path = curve
            fill.isHidden = !style.fill
            if style.fill {
                fill.frame = tape.bounds
                // 剖面线填充：工程图的截面表示法，比半透明渐变更“硬”，也不会糊成一片。
                fill.colors = nil
                fill.backgroundColor = hatchColor(style.color)
                let area = curve.mutableCopy()!
                area.addLine(to: CGPoint(x: points.last!.x, y: h))
                area.addLine(to: CGPoint(x: points.first!.x, y: h))
                area.closeSubpath()
                mask.path = area
            }
        }
    }

    /// 记录笔：右缘时刻 te = t − delay 处的插值值；关键帧覆盖到已知的最新样本为止。
    private func updatePens(_ input: Input, now: TimeInterval) {
        let plot = input.plot
        let scale = input.scale
        func y(_ v: Double) -> CGFloat { plot.maxY - CGFloat(min(v, scale * 1.5) / scale) * plot.height }
        let edgeNow = now - input.delay
        for (i, pen) in pens.enumerated() {
            pen.removeAnimation(forKey: "pen")
            guard i < input.series.count, let v0 = PPStreamChart.value(at: edgeNow, series: i, in: input.samples) else {
                pen.isHidden = true; continue
            }
            pen.isHidden = false
            var times: [TimeInterval] = [edgeNow]
            var values: [CGFloat] = [y(v0)]
            if input.frozenAt == nil {
                for s in input.samples where s.time > edgeNow {
                    times.append(s.time); values.append(y(s.values[safe: i] ?? 0))
                }
            }
            pen.position = CGPoint(x: plot.maxX, y: values.last!)
            let duration = times.last! - times.first!
            guard values.count >= 2, duration > 0.02 else { continue }
            let anim = CAKeyframeAnimation(keyPath: "position.y")
            anim.values = values
            anim.keyTimes = times.map { NSNumber(value: ($0 - edgeNow) / duration) }
            anim.duration = duration
            anim.calculationMode = .linear
            pen.add(anim, forKey: "pen")
        }
    }

    /// Catmull-Rom → 三次贝塞尔，控制点纵向夹在相邻点之间，避免过冲到负值。
    static func smoothPath(_ p: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
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
