import SwiftUI

// 测速台 HUD（定稿 docs/speedlab/design-final.webp，规格 docs/speedtest-spec.md §8）。
//
// 每个元素对应测量里的一个真实部件；动作只在它的事件发生时触发：
//   两翼     下行 / 上行通道。刻度 0–协商速率；下行亮部从源一侧（外）往执行端（内）长，上行反过来
//   读数     稳态吞吐（测速中为最新采样），字鼓 2 帧滚到新值
//   RTT      空载 / 负载延迟与真实 ping 采样直方图
//   SOURCE   候选源试跑结果 keep / drop
//   PIPELINE RUNNER → NIC → STREAMS ×n → EXIT → SRC，重连只在对应那一根上轻标
//   VERDICT  每个方向的瓶颈（LINK / UPSTREAM）与余量
//
// 设计坐标 1280×720，整体按宽度缩放。时间按 24fps 取整：平时静止，事件触发后按帧取动作。

// MARK: - 数据快照

struct SLHUDData {
    var runner = "—"
    var path = "—"
    var target = "—"
    var running = false
    var startedAt: Date?
    var finishedAt: Date?
    var phaseDates: [SLPhase: Date] = [:]
    var infoDates: [String: Date] = [:]
    var info: [String: String] = [:]
    var link: Int?
    var down: [SLTimedSample] = []
    var up: [SLTimedSample] = []
    var idle: [SLTimedSample] = []
    var sources: [SLSourceResult] = []
    var reconnects: [SLConnEvent] = []
    /// 没有可用源、被跳过的方向（dl / ul）。
    var skipped: Set<String> = []
    var downThreads = 12
    var upThreads = 4
    var isPublic = true
    var unit: SLUnit = .mbps
    var tick: Double = 0.25
    var error: String?

    init() {}

    var scale: Double { Double(link ?? 1000) }
    var done: Bool { finishedAt != nil && error == nil }

    /// 稳态：预热 2 秒后的中位数；平顶判定见 SLStat。
    func stat(_ s: [SLTimedSample]) -> SLStat? {
        SLStat.from(s.map(\.v), rtts: s.compactMap(\.rtt), tick: tick)
    }
}

// MARK: - 帧化动作（参数单位：帧，24fps）

enum SLMotion {
    static let fps = 24.0
    static func frames(_ now: Date, since t0: Date?) -> Int {
        guard let t0 else { return -1_000 }
        return Int(floor(now.timeIntervalSince(t0) * fps + 1e-6))
    }
    /// 标签恢复：0 → ⅓ → ⅔ → 1（01/07 段实测）。
    static func flick(_ k: Int) -> Double { k < 0 ? 0 : [0, 0.34, 0.67, 1][min(k, 3)] }
    /// 2 帧减速到位，不回弹。
    static func settle(_ k: Int) -> Double { k < 0 ? 0 : [0.62, 1][min(k, 1)] }
    /// 3 帧射出。
    static func shoot(_ k: Int) -> Double { k < 0 ? 0 : [0.35, 0.8, 1][min(k, 2)] }
    /// 预兆：正式出现前 2 帧的虚影。
    static func ghost(_ k: Int) -> Double { k == -2 ? 0.5 : (k == -1 ? 0.22 : 0) }
}

// MARK: - 视图

struct SLHUD: View {
    var data: SLHUDData
    var now: Date

    static let size = CGSize(width: 1280, height: 720)

    var body: some View {
        Canvas { ctx, size in
            let s = size.width / Self.size.width
            ctx.scaleBy(x: s, y: s)
            SLHUDPainter(ctx: ctx, d: data, now: now).paint()
        }
        .aspectRatio(Self.size.width / Self.size.height, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibility)
    }

    private var accessibility: String {
        let dl = data.stat(data.down).map { SLFormat.compact($0.stable, unit: data.unit) } ?? "—"
        let ul = data.stat(data.up).map { SLFormat.compact($0.stable, unit: data.unit) } ?? "—"
        return "测速 下行 \(dl) 上行 \(ul) \(data.unit.title)"
    }
}

// MARK: - 绘制

private struct SLHUDPainter {
    var ctx: GraphicsContext
    let d: SLHUDData
    let now: Date

    // 灰阶色板（深色主场；颜色只给异常）
    let ink = Color(white: 0.95), g1 = Color(white: 0.72), g2 = Color(white: 0.49), g3 = Color(white: 0.3)
    let g4 = Color(white: 0.17), g5 = Color(white: 0.11), bg = Color(red: 0.06, green: 0.063, blue: 0.07)
    let alert = Color(red: 1, green: 0.36, blue: 0.3)

    func k(_ t: Date?) -> Int { SLMotion.frames(now, since: t) }

    func paint() {
        var c = ctx
        c.fill(Path(CGRect(origin: .zero, size: SLHUD.size)), with: .color(bg))
        wings()
        readouts()
        modeBlock()
        rttPanel()
        sourcePanel()
        interfacePanel()
        pipeline()
        verdictPanel()
        progress()
    }

    // MARK: 原语

    func poly(_ p: [CGPoint], close: Bool = false) -> Path {
        var path = Path()
        guard let f = p.first else { return path }
        path.move(to: f)
        p.dropFirst().forEach { path.addLine(to: $0) }
        if close { path.closeSubpath() }
        return path
    }

    func fill(_ p: [CGPoint], _ c: Color, _ a: Double = 1) {
        var g = ctx; g.opacity = a; g.fill(poly(p, close: true), with: .color(c))
    }

    func stroke(_ p: [CGPoint], _ c: Color, _ w: CGFloat = 1, close: Bool = false, dash: [CGFloat] = [], a: Double = 1) {
        var g = ctx; g.opacity = a
        g.stroke(poly(p, close: close), with: .color(c), style: StrokeStyle(lineWidth: w, lineJoin: .miter, dash: dash))
    }

    func chamfer(_ r: CGRect, _ cut: CGFloat) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX - cut, y: r.minY), CGPoint(x: r.maxX, y: r.minY + cut),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX + cut, y: r.maxY), CGPoint(x: r.minX, y: r.maxY - cut)]
    }

    func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ c: Color,
              anchor: UnitPoint = .leading, weight: Font.Weight = .regular, track: CGFloat = 0, a: Double = 1) {
        guard a > 0 else { return }
        var g = ctx; g.opacity = a
        // 页面里 HUD 常只有设计宽度的 0.7 倍：注记类小字放大约 15%，保证缩放后仍 ≥ 9pt
        let size = size <= 12 ? size * 1.15 : size
        g.draw(Text(verbatim: s).font(.system(size: size, weight: weight, design: .monospaced)).tracking(track).foregroundColor(c),
               at: CGPoint(x: x, y: y), anchor: anchor)
    }

    /// [key] value 行：键淡、值亮。
    func row(_ key: String, _ value: String, _ x: CGFloat, _ y: CGFloat, keyWidth: CGFloat = 78, size: CGFloat = 12,
             valueColor: Color? = nil, a: Double = 1) {
        text("[\(key)]", x, y, size, g2, a: a)
        text(value, x + keyWidth, y, size, valueColor ?? g1, weight: .medium, a: a)
    }

    func node(_ p: CGPoint, _ r: CGFloat = 4, _ c: Color? = nil, a: Double = 1) {
        var g = ctx; g.opacity = a
        g.fill(Path(CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(c ?? ink))
        g.stroke(Path(CGRect(x: p.x - r - 4, y: p.y - r - 4, width: 2 * r + 8, height: 2 * r + 8)), with: .color(g3), lineWidth: 1)
    }

    /// 面板：斜切框 + 标题；进场 = 预兆虚影 2 帧 → 框到位 → 标题 0→⅓→⅔→1。返回内容透明度（未进场为 0）。
    @discardableResult
    func panel(_ r: CGRect, _ title: String, enter: Date?) -> Double {
        let f = k(enter)
        if f < 0 {
            let gh = SLMotion.ghost(f)
            if gh > 0 { stroke(chamfer(r, 18), g2, 1.2, close: true, a: gh) }
            else { stroke(chamfer(r, 18), g4, 1, close: true) }        // 未启用：最淡的框，骨架常驻
            text(title, r.minX + 18, r.minY + 20, 12, g3, weight: .bold, track: 1)
            return 0
        }
        fill(chamfer(r, 18), g5)
        stroke(chamfer(r, 18), g3, 1, close: true)
        stroke([CGPoint(x: r.minX + 10, y: r.minY + 34), CGPoint(x: r.maxX - 10, y: r.minY + 34)], g4, 1)
        stroke([CGPoint(x: r.minX - 6, y: r.minY + 30), CGPoint(x: r.minX - 6, y: r.maxY - 24), CGPoint(x: r.minX + 10, y: r.maxY - 8)], g3, 1.2)
        text(title, r.minX + 18, r.minY + 20, 12, ink, weight: .bold, track: 1, a: SLMotion.flick(f))
        return SLMotion.flick(f - 3)
    }

    // MARK: 两翼

    func wings() {
        wing(left: true, samples: d.down, enter: d.phaseDates[.dl], label: "DL")
        wing(left: false, samples: d.up, enter: d.phaseDates[.ul], label: "UL")
    }

    /// 一条通道。几何：外角（源一侧）→ 折点 → 内端（执行端一侧）。
    func wing(left: Bool, samples: [SLTimedSample], enter: Date?, label: String) {
        let sx: CGFloat = left ? -1 : 1, cx: CGFloat = 640
        let corner = CGPoint(x: cx + sx * 600, y: 66), fold = CGPoint(x: cx + sx * 410, y: 114), tip = CGPoint(x: cx + sx * 168, y: 172)
        let blade = [corner, fold, tip, CGPoint(x: tip.x - sx * 34, y: tip.y + 12), CGPoint(x: fold.x - sx * 6, y: fold.y + 44),
                     CGPoint(x: corner.x + sx * 22, y: corner.y + 16)]
        let f = k(enter)
        // 未启用：只留最淡的轮廓（底座的一部分）
        guard f >= 0 else {
            stroke(blade, g4, 1, close: true)
            node(corner, 3.5, g3)
            return
        }
        // 3 帧从内端射向外角：轮廓沿 x 方向展开
        let open = SLMotion.shoot(f)
        var g = ctx
        let reveal = left ? CGRect(x: tip.x - (tip.x - corner.x + 30) * open, y: 0, width: (tip.x - corner.x + 30) * open + 40, height: 260)
                          : CGRect(x: tip.x - 40, y: 0, width: (corner.x - tip.x + 30) * open + 40, height: 260)
        g.clip(to: Path(reveal))
        g.fill(poly(blade, close: true), with: .color(g5))
        g.stroke(poly(blade, close: true), with: .color(g3), lineWidth: 1)
        // 下方投影折面：通道的厚度
        g.fill(poly([CGPoint(x: fold.x + sx * 10, y: fold.y + 58), CGPoint(x: tip.x - sx * 20, y: tip.y + 26),
                     CGPoint(x: tip.x - sx * 70, y: tip.y + 34), CGPoint(x: fold.x - sx * 30, y: fold.y + 70)], close: true), with: .color(g4))
        // 亮部：吞吐 / 协商速率；下行从外角往内长（数据流入执行端），上行从内端往外长
        let value = displayValue(samples)
        let frac = min(1, value / d.scale)
        if frac > 0 {
            var lit = g
            let span = abs(corner.x - tip.x)
            let rect: CGRect = left
                ? CGRect(x: corner.x - 30, y: 0, width: 30 + span * frac, height: 260)
                : CGRect(x: tip.x - 40, y: 0, width: 40 + span * frac, height: 260)
            lit.clip(to: Path(rect))
            lit.fill(poly(blade, close: true), with: .color(ink))
        }
        // 刻度：0 / ¼ / ½ / ¾ / 满（协商速率），沿上沿平行
        for i in 0...4 {
            let r = CGFloat(i) / 4
            let x = left ? corner.x + (tip.x - corner.x) * r : tip.x + (corner.x - tip.x) * r
            let yTop = y(onTopEdgeAt: x, corner, fold, tip) - 14
            g.stroke(poly([CGPoint(x: x, y: yTop), CGPoint(x: x, y: yTop - 7)]), with: .color(g2), lineWidth: 1)
            // 外角那一格不标数字：会撞上通道标题
            guard abs(x - corner.x) > 40 else { continue }
            g.draw(Text(verbatim: SLFormat.tick(d.scale * Double(r))).font(.system(size: 11, design: .monospaced)).foregroundColor(g2),
                   at: CGPoint(x: x, y: yTop - 16), anchor: .center)
        }
        // 通道标签 + 百分比（亮部占协商速率）
        let a = SLMotion.flick(f - 3)
        let lx = left ? corner.x - 12 : corner.x + 12
        text("\(label) CHANNEL", lx, 18, 13, ink, anchor: left ? .leading : .trailing, weight: .bold, track: 1, a: a)
        text("0 – \(SLFormat.tick(d.scale)) \(d.unit.title)", lx, 36, 11, g2, anchor: left ? .leading : .trailing, a: a)
        if value > 0 {
            // 放在翼尖下方的暗处：压在亮部上会白字白底看不见
            text("\(Int((frac * 100).rounded()))%", tip.x - sx * 6, tip.y + 34, 15, ink, anchor: left ? .trailing : .leading, weight: .bold, a: a)
        }
        node(corner, 4)
    }

    /// 上沿折线在 x 处的 y。
    func y(onTopEdgeAt x: CGFloat, _ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        let (p, q) = (min(a.x, b.x)...max(a.x, b.x)).contains(x) ? (a, b) : (b, c)
        let t = (x - p.x) / (q.x - p.x == 0 ? 1 : q.x - p.x)
        return p.y + (q.y - p.y) * t
    }

    /// 当前显示值：测完 = 稳态中位数；测速中 = 最新采样（2 帧减速到位）。
    func displayValue(_ s: [SLTimedSample]) -> Double {
        if d.done, let st = d.stat(s) { return st.stable }
        guard let last = s.last else { return 0 }
        let prev = s.count > 1 ? s[s.count - 2].v : 0
        return prev + (last.v - prev) * SLMotion.settle(k(last.at))
    }

    // MARK: 读数

    func readouts() {
        readout(left: true, samples: d.down, enter: d.phaseDates[.dl], label: "↓ DL")
        readout(left: false, samples: d.up, enter: d.phaseDates[.ul], label: "↑ UL")
        stroke([CGPoint(x: 640, y: 214), CGPoint(x: 640, y: 330)], g3, 1)
        node(CGPoint(x: 640, y: 272), 3, g2)
    }

    func readout(left: Bool, samples: [SLTimedSample], enter: Date?, label: String) {
        let x: CGFloat = left ? 506 : 774, y: CGFloat = 300
        var v: Double?, prev: Double?, f = 9
        if d.done, let st = d.stat(samples) { v = st.stable; prev = samples.last?.v; f = k(d.finishedAt) }
        else if let last = samples.last { v = last.v; prev = samples.count > 1 ? samples[samples.count - 2].v : last.v; f = k(last.at) }
        drum(v.map { d.unit.value($0) }, prev.map { d.unit.value($0) }, f, x, y, 100)
        text("\(label) · \(d.unit.title)", x, y + 30, 18, g1, anchor: .center)
        // 标签行：上沿一道发丝线
        stroke([CGPoint(x: x - 150, y: y + 52), CGPoint(x: x + 150, y: y + 52)], g3, 1)
        guard let st = d.stat(samples) else { return }
        var items: [(String, String)] = [("peak", SLFormat.compact(st.peak, unit: d.unit))]
        let body = Array(samples.map(\.v).dropFirst(Int(2 / max(d.tick, 0.05))))
        if body.count > 3 { items.append(("cv", String(format: "%.1f%%", cv(body)))) }
        let a = d.done ? SLMotion.flick(k(d.finishedAt)) : 1
        var line = ""
        for (kk, vv) in items { line += "[\(kk)] \(vv)   " }
        text(String(line.dropLast(3)), x, y + 72, 12, g1, anchor: .center, a: a)
        _ = enter
    }

    func cv(_ a: [Double]) -> Double {
        let m = a.reduce(0, +) / Double(a.count)
        guard m > 0 else { return 0 }
        return sqrt(a.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(a.count)) / m * 100
    }

    /// 字鼓：每一位独立，2 帧滚到新值；裁剪框只包住数字。待机为最淡的 000。
    func drum(_ v: Double?, _ prev: Double?, _ f: Int, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat) {
        let fmt: (Double) -> String = { $0 >= 1000 ? String(format: "%.0f", $0) : ($0 >= 100 ? String(format: "%.0f", $0) : String(format: "%.1f", $0)) }
        let s = v.map(fmt) ?? "000"
        let p = prev.map(fmt) ?? s
        let cw = size * 0.6
        let n = CGFloat(s.count), x0 = x - cw * n / 2
        var g = ctx
        // 文本框底边比基线低一个下伸部（约 0.24 字号）；裁剪框从字顶到基线
        let bottom = y + size * 0.24
        g.clip(to: Path(CGRect(x: x0 - 6, y: y - size * 0.8, width: cw * n + 12, height: size * 0.84)))
        let pp = Array(p.count == s.count ? p : s)
        for (i, ch) in s.enumerated() {
            let old = pp[i], cx = x0 + cw * (CGFloat(i) + 0.5)
            let r: CGFloat = (ch != old && f >= 0 && f < 2) ? [0.5, 0.15][f] : 0
            let col = v == nil ? g4 : ink
            func glyph(_ c: Character, _ yy: CGFloat) {
                g.draw(Text(String(c)).font(.system(size: size, weight: .bold, design: .monospaced)).foregroundColor(col),
                       at: CGPoint(x: cx, y: yy), anchor: .bottom)
            }
            if r > 0 { glyph(ch, bottom + size * 0.8 * r); glyph(old, bottom - size * 0.8 * (1 - r)) }
            else { glyph(ch, bottom) }
        }
    }

    // MARK: 模式块

    func modeBlock() {
        let modes: [(SLPhase, String)] = [(.prepare, "PREPARE"), (.idle, "LATENCY"), (.pick, "SOURCE"), (.dl, "DOWNLINK"), (.ul, "UPLINK"), (.done, "THROUGHPUT")]
        var cur: (SLPhase, String, Date?) = (.prepare, "STANDBY", nil)
        for (p, name) in modes { if let t = d.phaseDates[p], cur.2 == nil || t >= cur.2! { cur = (p, name, t) } }
        if d.startedAt == nil { cur = (.prepare, d.done ? "THROUGHPUT" : "STANDBY", nil) }
        let f = k(cur.2), y: CGFloat = 398, h: CGFloat = 38, cx: CGFloat = 640
        let state = d.error != nil ? "FAIL" : (d.running ? "RUN" : (d.done ? "DONE" : "IDLE"))
        if f >= 0 && f < 3 && cur.2 != nil {
            let half: CGFloat = [560, 260, 140][f]
            fill(chamfer(CGRect(x: cx - half, y: f == 0 ? y + 12 : y, width: half * 2, height: f == 0 ? 14 : h), 12), ink)
        } else {
            fill(chamfer(CGRect(x: cx - 140, y: y, width: 280, height: h), 12), d.error != nil ? alert : ink)
        }
        let ta = cur.2 == nil ? 1 : SLMotion.flick(f - 2)
        text(d.error != nil ? "ERROR" : cur.1, cx, y + h / 2, 22, bg, anchor: .center, weight: .bold, track: 5, a: ta)
        let sa = cur.2 == nil ? 1 : SLMotion.flick(f)
        text(state, cx - 160, y + h / 2, 14, d.error != nil ? alert : ink, anchor: .trailing, weight: .bold, track: 2, a: sa)
        let stamp: String
        if let fin = d.finishedAt { stamp = fin.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour(.twoDigits(amPM: .omitted)).minute().second()) }
        else if let st = d.startedAt { stamp = String(format: "T+%05.2f s", now.timeIntervalSince(st)) }
        else { stamp = "—" }
        text(stamp, cx + 160, y + h / 2, 13, g1, a: sa)
        let line = d.error ?? "[runner] \(d.runner)   [path] \(d.path)   [target] \(d.target)"
        text(line, cx, y + h + 22, 12, d.error != nil ? alert : g1, anchor: .center)
    }

    // MARK: 左上：RTT

    func rttPanel() {
        let r = CGRect(x: 28, y: 200, width: 290, height: 258)
        let a = panel(r, "RTT", enter: d.phaseDates[.idle])
        guard a > 0 else { return }
        let idle = d.idle.map(\.v), loaded = (d.down + d.up).compactMap(\.rtt)
        let idleM = idle.isEmpty ? nil : SLStat.median(idle), loadM = loaded.isEmpty ? nil : SLStat.median(loaded)
        row("idle", idleM.map { String(format: "%.1f ms", $0) } ?? "—", r.minX + 20, r.minY + 56, a: a)
        row("load", loadM.map { String(format: "%.1f ms", $0) } ?? "—", r.minX + 20, r.minY + 76, a: a)
        if let i = idleM, let l = loadM {
            let delta = l - i
            row("delta", String(format: "%+.1f ms", delta), r.minX + 20, r.minY + 96, a: a)
            // 负载下延迟涨超过 30 ms 视为队列膨胀（bufferbloat），这是异常，才上色
            row("state", delta > 30 ? "BLOAT" : "STABLE", r.minX + 20, r.minY + 116, valueColor: delta > 30 ? alert : g1, a: a)
        }
        // 直方图：每个 ping 采样落一格；空载淡、负载亮。新采样到达那一帧所在格子才动
        let all = idle.map { ($0, false) } + loaded.map { ($0, true) }
        guard !all.isEmpty else { return }
        let lo = max(0, (all.map(\.0).min() ?? 0) - 0.5), hi = (all.map(\.0).max() ?? 1) + 0.5
        let bins = 12
        var cnt = [Double](repeating: 0, count: bins), hot = [Bool](repeating: false, count: bins)
        for (v, l) in all {
            let b = min(bins - 1, max(0, Int((v - lo) / (hi - lo) * Double(bins))))
            cnt[b] += 1; if l { hot[b] = true }
        }
        let mx = cnt.max() ?? 1, base = r.maxY - 30, bw: CGFloat = 16
        stroke([CGPoint(x: r.minX + 20, y: base), CGPoint(x: r.maxX - 24, y: base)], g3, 1, a: a)
        for i in 0..<bins where cnt[i] > 0 {
            let h = CGFloat(cnt[i] / mx) * 76, x = r.minX + 24 + CGFloat(i) * (bw + 5)
            fill([CGPoint(x: x, y: base - h), CGPoint(x: x + bw, y: base - h), CGPoint(x: x + bw, y: base), CGPoint(x: x, y: base)], hot[i] ? g1 : g2, a)
        }
        text(String(format: "%.1f", lo), r.minX + 20, base + 14, 10, g2, a: a)
        text(String(format: "%.1f ms", hi), r.maxX - 24, base + 14, 10, g2, anchor: .trailing, a: a)
    }

    // MARK: 右上：选源

    func sourcePanel() {
        let r = CGRect(x: 962, y: 200, width: 290, height: 258)
        let a = panel(r, "SOURCE", enter: d.isPublic ? d.phaseDates[.pick] : d.phaseDates[.idle])
        guard a > 0 else { return }
        if !d.isPublic {
            row("target", d.target, r.minX + 20, r.minY + 56, a: a)
            row("addr", d.info["target"] ?? "—", r.minX + 20, r.minY + 76, a: a)
            row("engine", "iperf3", r.minX + 20, r.minY + 96, a: a)
            return
        }
        // 候选源：每个结果到达那一刻 0→⅓→⅔→1 进场；淘汰的变暗并划线
        var y = r.minY + 58
        for dir in ["dl", "ul"] {
            let list = d.sources.filter { $0.dir == dir }
            guard !list.isEmpty else { continue }
            text(dir == "dl" ? "↓ DL" : "↑ UL", r.minX + 20, y, 11, g2, weight: .bold, a: a)
            y += 18
            for s in list {
                let fa = a * SLMotion.flick(k(s.at))
                let col = s.keep ? ink : g3
                text(s.shortName, r.minX + 32, y, 12, col, weight: .medium, a: fa)
                text("\(Int(s.mbps)) Mbps", r.minX + 196, y, 12, s.keep ? g1 : g3, anchor: .trailing, a: fa)
                text(s.keep ? "KEEP" : "DROP", r.maxX - 22, y, 11, s.keep ? ink : g3, anchor: .trailing, weight: .bold, a: fa)
                if !s.keep { stroke([CGPoint(x: r.minX + 30, y: y), CGPoint(x: r.minX + 198, y: y)], g3, 1, a: fa) }
                y += 18
            }
            y += 6
        }
        // 入选源的地址
        if let ip = d.info["src_ip"] {
            stroke([CGPoint(x: r.minX + 20, y: r.maxY - 40), CGPoint(x: r.maxX - 20, y: r.maxY - 40)], g4, 1, a: a)
            row("ip", ip, r.minX + 20, r.maxY - 22, keyWidth: 44, a: a * SLMotion.flick(k(d.infoDates["src_ip"])))
        }
    }

    // MARK: 左下：本机网口

    func interfacePanel() {
        let r = CGRect(x: 28, y: 478, width: 252, height: 176)
        let a = panel(r, "INTERFACE", enter: d.infoDates["link"] ?? d.infoDates["iface"])
        guard a > 0 else { return }
        let degraded = (d.link ?? 1000) <= 100 && !(d.info["link"] ?? "").contains("Wi-Fi")
        row("if", d.info["phy"] ?? d.info["iface"] ?? "—", r.minX + 20, r.minY + 56, keyWidth: 60, a: a)
        row("link", linkText, r.minX + 20, r.minY + 76, keyWidth: 60, valueColor: degraded ? alert : nil, a: a)
        row("mtu", d.info["mtu"].flatMap { $0.isEmpty ? nil : $0 } ?? "—", r.minX + 20, r.minY + 96, keyWidth: 60, a: a)
        let dl = d.stat(d.down).map { "\(Int(($0.stable / d.scale * 100).rounded()))%" } ?? "—"
        let ul = d.stat(d.up).map { "\(Int(($0.stable / d.scale * 100).rounded()))%" } ?? "—"
        row("util", "DL \(dl) · UL \(ul)", r.minX + 20, r.minY + 116, keyWidth: 60, a: a)
    }

    var linkText: String {
        let raw = d.info["link"] ?? ""
        let parts = raw.split(separator: " ")
        guard let v = parts.first.flatMap({ Int($0) }) else { return raw.isEmpty ? "—" : raw }
        let speed = v >= 1000 ? "\(v)BASE-T" : "\(v)BASE-TX"
        let rest = parts.dropFirst().joined(separator: " ")
        if rest.contains("Wi-Fi") { return "Wi-Fi \(v) Mbps" }
        return speed + (rest == "full" ? " FD" : (rest == "half" ? " HD" : ""))
    }

    // MARK: 中下：测量链路

    func pipeline() {
        let r = CGRect(x: 300, y: 470, width: 680, height: 108)
        let a = panel(r, "PIPELINE", enter: d.startedAt)
        guard a > 0 else { return }
        let y = r.minY + 70
        let srcName = d.isPublic ? (d.sources.first { $0.keep && $0.dir == "dl" }?.shortName ?? "—") : d.target
        let exitIP = (d.info["exit"] ?? "").replacingOccurrences(of: "当前 IP：", with: "").split(separator: " ").first.map(String.init)
        let nodes: [(String, String, Date?)] = [
            ("RUNNER", d.runner, d.startedAt),
            ("NIC", d.info["phy"] ?? d.info["iface"] ?? "—", d.infoDates["iface"]),
            ("STREAMS", "", d.phaseDates[.dl] ?? d.phaseDates[.ul]),
            (d.isPublic ? "EXIT" : "PATH", d.isPublic ? (exitIP ?? "—") : (d.info["iface"] ?? "—"), d.infoDates["exit"] ?? d.infoDates["iface"]),
            (d.isPublic ? "SRC" : "TARGET", srcName, d.sources.first?.at ?? d.phaseDates[.dl]),
        ]
        let xs: [CGFloat] = [r.minX + 64, r.minX + 186, r.minX + 340, r.minX + 494, r.minX + 616]
        for (i, (title, sub, t)) in nodes.enumerated() {
            let f = k(t), x = xs[i]
            if i > 0 {
                let on = f >= 0
                stroke([CGPoint(x: xs[i - 1] + (i - 1 == 2 ? 74 : 50), y: y), CGPoint(x: x - (i == 2 ? 74 : 50), y: y)], on ? g1 : g4, 1.5, a: a)
                if on { node(CGPoint(x: (xs[i - 1] + x) / 2 + (i == 3 ? 37 : (i == 2 ? -37 : 0)), y: y), 3, g1, a: a) }
            }
            if i == 2 { streams(x, y, f, a); continue }
            let box = CGRect(x: x - 50, y: y - 22, width: 100, height: 44)
            if f < 0 {
                stroke(chamfer(box, 10), g4, 1, close: true, a: a)
                text(title, x, y - 6, 12, g3, anchor: .center, weight: .bold, a: a)
                continue
            }
            fill(chamfer(box, 10), g4, a)
            stroke(chamfer(box, 10), g3, 1, close: true, a: a)
            text(title, x, y - 7, 12, ink, anchor: .center, weight: .bold, track: 1, a: a * SLMotion.flick(f))
            text(sub, x, y + 10, 10, g1, anchor: .center, a: a * SLMotion.flick(f - 2))
        }
    }

    /// STREAMS：一根线一条连接；当前方向的连接数；重连那一根变暗 12 帧，再闪回。
    func streams(_ x: CGFloat, _ y: CGFloat, _ f: Int, _ a: Double) {
        let ulActive = d.phaseDates[.ul] != nil && !(d.done)
        let n = max(1, ulActive ? d.upThreads : d.downThreads), dir = ulActive ? "ul" : "dl"
        let w: CGFloat = 148, h: CGFloat = min(44, CGFloat(n) * 4 + 4)
        let label = f >= 0 ? "STREAMS ×\(n)" : "STREAMS"
        text(label, x, y - 34, 12, f >= 0 ? ink : g3, anchor: .center, weight: .bold, track: 1, a: a)
        guard f >= 0 else {
            stroke([CGPoint(x: x - w / 2, y: y), CGPoint(x: x + w / 2, y: y)], g4, 1, a: a)
            return
        }
        for i in 0..<n {
            let yy = y - h / 2 + (n == 1 ? h / 2 : h * CGFloat(i) / CGFloat(n - 1))
            var col = g1, ea = a
            if let ev = d.reconnects.last(where: { $0.dir == dir && $0.n == i }) {
                let kk = k(ev.at)
                if kk >= 0 && kk < 12 { col = g3 } else if kk >= 12 && kk < 14 { col = ink; ea = a * SLMotion.ghost(kk - 14) * 2 }
            }
            stroke([CGPoint(x: x - w / 2, y: yy), CGPoint(x: x + w / 2, y: yy)], col, 1.2, a: ea * SLMotion.flick(f - i / 3))
        }
        // 两端夹具
        for e in [x - w / 2 - 6, x + w / 2 + 6] {
            stroke([CGPoint(x: e, y: y - h / 2 - 6), CGPoint(x: e, y: y + h / 2 + 6)], g2, 2, a: a)
        }
        let rc = d.reconnects.filter { $0.dir == dir }.count
        if rc > 0 { text("reconn \(rc)", x, y + h / 2 + 16, 10, g2, anchor: .center, a: a) }
    }

    // MARK: 右下：判断

    func verdictPanel() {
        let r = CGRect(x: 1000, y: 478, width: 252, height: 176)
        let a = panel(r, "VERDICT", enter: d.phaseDates[.dl] ?? d.phaseDates[.ul])
        guard a > 0 else { return }
        func judge(_ s: [SLTimedSample]) -> (String, String, Bool) {
            guard let st = d.stat(s) else { return ("—", "—", false) }
            let head = max(0, 1 - st.stable / d.scale)
            let b = !st.flat ? (d.done ? "—" : "…") : (st.stable >= d.scale * 0.9 ? "LINK" : "UPSTREAM")
            return (b, "\(Int((head * 100).rounded()))%", false)
        }
        var dl = judge(d.down), ul = judge(d.up)
        if d.skipped.contains("dl") { dl = ("NO SRC", "—", false) }
        if d.skipped.contains("ul") { ul = ("NO SRC", "—", false) }
        let fa = d.done ? a * SLMotion.flick(k(d.finishedAt)) : a
        row("DL", dl.0, r.minX + 20, r.minY + 56, keyWidth: 44, valueColor: ink, a: fa)
        row("UL", ul.0, r.minX + 20, r.minY + 76, keyWidth: 44, valueColor: ink, a: fa)
        row("headroom", "DL \(dl.1) · UL \(ul.1)", r.minX + 20, r.minY + 104, keyWidth: 100, a: fa)
    }

    // MARK: 阶段条 + START 位置（按钮本身由页面叠一个真按钮）

    func progress() {
        let cells: [(String, SLPhase, SLPhase)] = [("RTT", .idle, .pick), ("SRC", .pick, .dl), ("DL", .dl, .ul), ("UL", .ul, .done)]
        let y: CGFloat = 600, w: CGFloat = 118
        for (i, (lab, a0, a1)) in cells.enumerated() {
            let x0: CGFloat = 640 - 2 * (w + 8) + CGFloat(i) * (w + 8)
            let box = [CGPoint(x: x0 + 8, y: y), CGPoint(x: x0 + w, y: y), CGPoint(x: x0 + w - 8, y: y + 22), CGPoint(x: x0, y: y + 22)]
            let started = d.phaseDates[a0], ended = d.phaseDates[a1]
            if ended != nil { fill(box, ink, SLMotion.flick(k(ended))) }
            else if started != nil { fill(box, g3, SLMotion.flick(k(started))) }
            stroke(box, g3, 1, close: true)
            let col = ended != nil ? bg : (started != nil ? ink : g2)
            text(lab, x0 + w / 2 + 3, y + 11, 12, col, anchor: .center, weight: .bold, track: 1)
            let skip = (lab == "DL" && d.skipped.contains("dl")) || (lab == "UL" && d.skipped.contains("ul"))
            let st = skip ? "SKIP" : (ended != nil ? "DONE" : (started != nil ? "RUN" : "—"))
            text(st, x0 + w / 2, y + 36, 10, started != nil ? g1 : g3, anchor: .center)
        }
    }
}
