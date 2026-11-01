import AppKit
import CoreImage
import SwiftUI

// 全息模式：路由追踪页打开时，地球铺满整个窗口当背景（侧栏磁贴与页面内容都浮在上面），
// 地球中心对准侧栏右边的内容区。镜头状态放在共享对象里：背景的地球与页面上的按钮（缩放、AUTO）用同一份。
//
// 操作（与苹果地图一致）：
//   单指按下拖 / 双指滑动   转地球（展平后是平移地图）；按下拖松手有惯性，双指滑动用系统自带的惯性
//   双指按下拖               挪动整个视图（地球在窗口里的位置）
//   捏合 / 鼠标滚轮 / ⌘+双指滑动   以指针处为中心缩放；捏合松手有惯性，滚轮每格平滑滑过去
//   双击 放大一档，⌥ 双击 缩小一档（以点击处为中心）
//   方向键 转动，+ / - 缩放，Esc 回到跟拍并把视图挪回原位

@MainActor
final class TraceMapModel: ObservableObject {
    static let shared = TraceMapModel()

    @Published var flight = TraceFlight(TraceCam.introStart)
    /// 用户接管了镜头（缩放 / 拖动后）；false = 跟拍航线。
    @Published var manual = false
    /// 最新一站出现 2.5 秒后置位：跟拍从「最新一段」拉远到「全程」。
    @Published var settled = false
    /// 飞行 / 惯性结束时加一，让逐帧刷新及时停下。
    @Published var frameCheck = 0
    /// 页面顶部浮层（标题 + 目标栏）的底边，窗口坐标：地球中心对准它以下的区域。
    @Published var topInset: CGFloat = 0
    /// 用户挪动视图的位移（双指按下拖）：只挪地球在窗口里的位置，不改大小。
    @Published var pan: CGSize = .zero
    var gestureBase: TraceCam?

    /// 背景层的画幅与默认偏移：键盘 / 滚动 / 缩放锚点换算用（由 TraceGlobeStage 布局时写入）。
    var stageSize: CGSize = .zero
    var shift: CGSize = .zero
    /// 侧栏（含拖拽条）宽度：侧栏上的滚动不归地球。
    var leading: CGFloat = 0

    var minSide: Double { TraceGlobeProjection.side(stageSize, shift) }
    /// 地球中心在画幅里的位置。
    var origin: CGPoint {
        CGPoint(x: stageSize.width / 2 + shift.width + pan.width, y: stageSize.height / 2 + shift.height + pan.height)
    }

    /// 用户接管镜头：手势跟手直接到位，按钮走飞行，停手一阵后自转。
    func takeOver(_ c: TraceCam, animated: Bool) {
        manual = true
        if animated {
            flight.fly(to: c)
            flight.setSpin(true)
        } else {
            flight.jump(to: c)
        }
    }

    /// 缩放；给了锚点（画幅坐标）就让锚点下的地方停在原处，没给就以视野中心为准。
    /// glide：指数缓停地滑过去（滚轮、捏合松手的惯性），连续调用时接着滑、不跳。
    func zoom(by factor: Double, at anchor: CGPoint? = nil, from base: TraceCam? = nil, animated: Bool = true, glide: Bool = false) {
        let b = base ?? (animated || glide ? flight.to : flight.cam(at: Date()))
        var c = b
        c.zoom = min(TraceCam.maxZoom, max(TraceCam.minZoom, b.zoom * factor))
        if let anchor {
            // 锚点相对中心的位移 d：放大 f 倍后中心要往锚点挪 d·(1 − 1/f)，锚点才留在原处
            let f = c.zoom / b.zoom
            let d = CGSize(width: anchor.x - origin.x, height: anchor.y - origin.y)
            let moved = b.dragged(dx: -d.width * (1 - 1 / f), dy: -d.height * (1 - 1 / f), minSide: minSide)
            c.lon = moved.lon; c.lat = moved.lat
        }
        if glide {
            manual = true
            flight.glide(to: c.clamped())
            flight.setSpin(true)
        } else {
            takeOver(c.clamped(), animated: animated)
        }
    }

    // MARK: 捏合惯性

    /// 捏合过程中最近一小段的（时刻, ln 放大倍数）：松手时按这段的速度继续缩放。
    private var pinchSamples: [(t: TimeInterval, v: Double)] = []
    private var pinchAnchor: CGPoint?

    func pinchChanged(_ magnification: Double, anchor: CGPoint, base: TraceCam) {
        let now = CACurrentMediaTime()
        pinchSamples.append((now, log(max(1e-3, magnification))))
        pinchSamples.removeAll { now - $0.t > 0.1 }
        pinchAnchor = anchor
        zoom(by: magnification, at: anchor, from: base, animated: false)
    }

    /// 松手：按最后约 0.1 秒的捏合速度再缩放一段（相当于继续捏 0.25 秒），指数缓停；捏得慢就不滑。
    func pinchEnded() {
        defer { pinchSamples = []; pinchAnchor = nil }
        let now = CACurrentMediaTime()
        guard let first = pinchSamples.first, let last = pinchSamples.last, last.t - first.t > 0.02, now - last.t < 0.08 else {
            flight.setSpin(true)
            return
        }
        let rate = (last.v - first.v) / (last.t - first.t)      // ln 倍数 / 秒
        guard abs(rate) > 0.4 else { flight.setSpin(true); return }
        let factor = exp(max(-0.7, min(0.7, rate * 0.25)))
        zoom(by: factor, at: pinchAnchor, from: flight.cam(at: Date()), glide: true)
    }

    /// 按屏幕位移转地球 / 平移地图（与单指拖同一套换算），跟手不走飞行。
    func nudge(dx: Double, dy: Double, animated: Bool = false) {
        let base = animated ? flight.to : flight.cam(at: Date())
        takeOver(base.dragged(dx: dx, dy: dy, minSide: minSide), animated: animated)
    }

    /// 回到跟拍，视图挪回原位。
    func follow() {
        manual = false
        pan = .zero
    }

    // MARK: 系统事件（SwiftUI 没有的：双指滑动、右键拖、滚轮、键盘）

    private var monitor: Any?
    private var panning = false

    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .rightMouseDown, .rightMouseDragged, .rightMouseUp, .keyDown]) { [weak self] e in
            guard let self else { return e }
            return self.handle(e) ? nil : e
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panning = false
    }

    /// 事件落在地球上（不在侧栏、不在可滚动的浮层或输入框里）才接。返回 true = 已处理、吞掉。
    private func handle(_ e: NSEvent) -> Bool {
        // 只接地球所在的主窗口：不是浮动面板、没有弹出的表单，内容区就是地球画幅
        guard let window = e.window, !(window is NSPanel), window.sheets.isEmpty, let content = window.contentView,
              abs(content.bounds.width - stageSize.width) < 1, abs(content.bounds.height - stageSize.height) < 1 else { return false }
        if e.type == .keyDown { return key(e, window: window) }
        let loc = e.locationInWindow
        let p = CGPoint(x: loc.x, y: content.bounds.height - loc.y)
        switch e.type {
        case .rightMouseDown:
            guard onGlobe(p, loc, content) else { return false }
            panning = true
            return true
        case .rightMouseDragged:
            guard panning else { return false }
            manual = true
            pan.width = min(stageSize.width / 2, max(-stageSize.width / 2, pan.width + e.deltaX))
            pan.height = min(stageSize.height / 2, max(-stageSize.height / 2, pan.height + e.deltaY))
            return true
        case .rightMouseUp:
            guard panning else { return false }
            panning = false
            return true
        case .scrollWheel:
            guard onGlobe(p, loc, content) else { return false }
            scroll(e, at: p)
            return true
        default:
            return false
        }
    }

    private func scroll(_ e: NSEvent, at p: CGPoint) {
        let ended = e.momentumPhase == .ended || (e.phase == .ended && e.momentumPhase == [])
        if e.hasPreciseScrollingDeltas && !e.modifierFlags.contains(.command) {
            // 触控板双指滑动：和按下拖一样转地球；松手后的惯性由系统的 momentum 事件继续送来
            if e.scrollingDeltaX != 0 || e.scrollingDeltaY != 0 {
                nudge(dx: e.scrollingDeltaX, dy: e.scrollingDeltaY)
            }
        } else {
            // 鼠标滚轮 / ⌘+双指滑动：缩放。触控板按像素连续、跟手（松手后系统的 momentum 事件接着送，自带惯性）；
            // 滚轮一格约 1.15 倍，不跳格：从当前画面滑过去，连续滚动时目标累加、接着滑
            if e.hasPreciseScrollingDeltas {
                if e.scrollingDeltaY != 0 { zoom(by: exp(e.scrollingDeltaY * 0.01), at: p, animated: false) }
            } else if e.scrollingDeltaY != 0 {
                zoom(by: exp(e.scrollingDeltaY * 0.14), at: p, glide: true)
            }
        }
        if ended || !e.hasPreciseScrollingDeltas { flight.setSpin(true) }
    }

    private func key(_ e: NSEvent, window: NSWindow) -> Bool {
        // 输入框在编辑时键盘归它
        if window.firstResponder is NSText { return false }
        guard e.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        let step = minSide * 0.12
        switch e.keyCode {
        case 123: nudge(dx: step, dy: 0, animated: true)      // ←
        case 124: nudge(dx: -step, dy: 0, animated: true)     // →
        case 125: nudge(dx: 0, dy: -step, animated: true)     // ↓
        case 126: nudge(dx: 0, dy: step, animated: true)      // ↑
        case 53: follow()                                     // Esc
        default:
            switch e.charactersIgnoringModifiers {
            case "+", "=": zoom(by: 1.8)
            case "-", "_": zoom(by: 1 / 1.8)
            default: return false
            }
        }
        return true
    }

    /// 点在地球上：侧栏右边，且命中的不是可滚动的浮层（详情抽屉）。
    private func onGlobe(_ p: CGPoint, _ loc: NSPoint, _ content: NSView) -> Bool {
        guard p.x > leading else { return false }
        var v = content.hitTest(content.convert(loc, from: nil))
        while let view = v {
            if view is NSScrollView || view is NSText { return false }
            v = view.superview
        }
        return true
    }
}

/// 窗口背景层：整窗大小的地球 + 航线，接拖动 / 捏合 / 双击。只在路由追踪页挂上。
struct TraceGlobeStage: View {
    /// 侧栏（含拖拽条）占的宽度：地球中心对准它右边的内容区。
    var leading: CGFloat

    @ObservedObject private var trace = TraceStore.shared
    @ObservedObject private var visibility = WgWindowVisibility.shared
    @ObservedObject private var model = TraceMapModel.shared
    @Environment(\.colorScheme) private var scheme
    /// 窗口是否在焦点：失焦时自转缓停，回到焦点再转一阵。
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        let route = TraceRoute(trace)
        // 手动操作过就停在手动视角；点 AUTO / Esc / 开始新的追踪才回到跟拍
        let target: TraceCam? = model.manual ? nil : Self.follow(route.stops, settled: model.settled && !trace.running)
        // 自转：待机（没有航线）或手动操作后；跟拍航线时不转，免得把航线转出画面
        let wantSpin = (route.stops.isEmpty && !trace.running) || model.manual
        _ = model.frameCheck
        // SwiftUI 层逐帧刷新只在确实需要时开：有航线 / 追踪中（航线层要动）、镜头飞行或惯性（球面明暗随缩放变）。
        // 地图本身由 Metal 视图按屏幕刷新自己推进，不靠这个。飞行 / 惯性结束时 frameCheck 加一，这里重算后关掉
        // 航线上的脉冲只在追踪中和结束后 1 分钟内流动，之后定格成静态画面（不然做过一次追踪，静止待机也一直 120 帧在画）
        let routeLive = !route.stops.isEmpty && (trace.running || (trace.finishedAt.map { Date().timeIntervalSince($0) < Self.routeLive } ?? false))
        let needsFrames = visibility.isMainWindowVisible && (routeLive || model.flight.fastMoving)
        return GeometryReader { geo in
            let shift = CGSize(width: leading / 2, height: model.topInset / 2)
            // 拖动换算与地球大小用同一基准：可见区域的短边
            let minSide = TraceGlobeProjection.side(geo.size, shift)
            // 每帧都在动的部分放进独立宿主：逐帧刷新只在宿主内部，不带着整窗重新布局
            TraceIsolatedHost(content: AnyView(
                TraceMapLive(flight: model.flight, route: route, focus: trace.focus,
                             visible: visibility.isMainWindowVisible, running: trace.running,
                             shift: shift, pan: model.pan, needsFrames: needsFrames)
                    .environment(\.colorScheme, scheme)
            ))
            .contentShape(Rectangle())
            // 触控板双指捏合：以捏合起点为中心缩放
            .gesture(MagnifyGesture()
                .onChanged { g in
                    let base = model.gestureBase ?? model.flight.cam(at: Date())
                    if model.gestureBase == nil { model.gestureBase = base }
                    model.pinchChanged(g.magnification, anchor: g.startLocation, base: base)
                }
                .onEnded { _ in
                    model.gestureBase = nil
                    // 松手按捏合速度继续缩放一段，指数缓停
                    model.pinchEnded()
                })
            // 拖动：地球形态是转球，平面形态是平移；松手按速度滑出去
            .simultaneousGesture(DragGesture(minimumDistance: 2)
                .onChanged { g in
                    let base = model.gestureBase ?? model.flight.cam(at: Date())
                    if model.gestureBase == nil { model.gestureBase = base }
                    model.takeOver(base.dragged(dx: g.translation.width, dy: g.translation.height, minSide: minSide), animated: false)
                }
                .onEnded { g in
                    model.gestureBase = nil
                    let v = model.flight.to.angularVelocity(vx: g.velocity.width, vy: g.velocity.height, minSide: minSide)
                    model.flight.release(lon: v.lon, lat: v.lat)
                    model.flight.setSpin(true)
                })
            // 双击放大、⌥ 双击缩小，以点击处为中心
            .onTapGesture(count: 2) { p in
                model.zoom(by: NSEvent.modifierFlags.contains(.option) ? 1 / 2 : 2, at: p)
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { model.stageSize = $0 }
            .onChange(of: shift, initial: true) { _, s in model.shift = s }
        }
        .ignoresSafeArea()
        .onAppear {
            model.leading = leading
            model.startMonitoring()
        }
        .onChange(of: leading) { _, v in model.leading = v }
        .onDisappear { model.stopMonitoring() }
        .task { await TraceBench.runIfRequested() }
        // 镜头飞行：新站点进来时从当前画面飞到新视角
        .onChange(of: target) { _, next in if let next { model.flight.fly(to: next) } }
        .onChange(of: trace.startedAt) { _, _ in model.follow() }
        .onChange(of: wantSpin, initial: true) { _, on in model.flight.setSpin(on) }
        // 省电：窗口失去焦点，自转非线性缓停到 0 后静止（不再画）；回到焦点重新转一阵（前台也只转 1 分钟，到点同样缓停）
        .onChange(of: activeState) { _, state in
            if state == .key {
                if wantSpin { model.flight.restartSpin() }
            } else {
                model.flight.easeSpinToStop()
            }
        }
        // 开场：没有航线时，从半屏完整地球边转边推近到本地区域，然后接自转
        .onAppear {
            guard route.stops.isEmpty, !trace.running, !model.manual else { return }
            model.flight.jump(to: TraceCam.introStart)
            model.flight.fly(to: TraceCam.introEnd, span: 2.4)
            model.flight.setSpin(true)
        }
        // 飞行 / 惯性结束的时刻重算一次是否还需要逐帧刷新
        .task(id: "\(model.flight.at.timeIntervalSinceReferenceDate)|\(model.flight.fling?.at.timeIntervalSinceReferenceDate ?? 0)") {
            try? await Task.sleep(for: .seconds(max(model.flight.span, TraceFlight.inertia * 5) + 0.1))
            if !Task.isCancelled { model.frameCheck &+= 1 }
        }
        // 追踪结束 1 分钟到点：重算一次，航线脉冲定格
        .task(id: trace.finishedAt) {
            guard trace.finishedAt != nil else { return }
            try? await Task.sleep(for: .seconds(Self.routeLive + 0.2))
            if !Task.isCancelled { model.frameCheck &+= 1 }
        }
        // 每出现一站重新计时：停稳 2.5 秒才拉远看全程
        .task(id: route.stops.count) {
            model.settled = false
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { model.settled = true }
        }
    }

    /// 追踪结束后航线脉冲再流动多久。
    static let routeLive: TimeInterval = 60

    /// 跟拍：追踪中、或最新一站出现不久，只框最新一段（上一站 → 新站）；全部画完停稳后拉远看全程。
    static func follow(_ stops: [TraceStop], settled: Bool) -> TraceCam? {
        TraceCam.fit((settled ? stops : Array(stops.suffix(2))).map { ($0.lon, $0.lat) })
    }
}

/// 全息模式下侧栏底下的压暗：模糊本身在地图渲染的上屏那一趟里做（TraceMetalMap，模糊半径随横向位置连续变化），
/// 这里沿同一条曲线叠一层很淡的压暗，磁贴读得清，越靠侧栏右缘越弱。
struct TraceSidebarBlur: View {
    private static let start = 0.2

    /// 沿 smootherstep 取 12 个节点：两头平、中间缓，看不出起止点。
    private static func fade(_ peak: Double) -> Gradient {
        Gradient(stops: (0...11).map { i in
            let t = Double(i) / 11
            let x = max(0, (t - start) / (1 - start))
            let e = x * x * x * (x * (x * 6 - 15) + 10)
            return .init(color: Color.black.opacity(peak * (1 - e)), location: t)
        })
    }

    var body: some View {
        // 模糊本身在地图渲染里（TraceMetalMap），这里只叠同一条曲线的压暗
        LinearGradient(gradient: Self.fade(0.28), startPoint: .leading, endPoint: .trailing)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

extension View {
    /// 全息模式的悬浮控件：不磨砂，地球从底下透上来；只垫一层很淡的压暗保证字读得清，
    /// 外框是一圈发丝线 + 四角瞄准角标（图纸 / HUD 的取景框）。active 时框线与角标提亮。
    /// fill：压暗的浓度；字多的大面板（详情抽屉）给深一些。
    func traceHolo(active: Bool = false, fill: Double = 0.34) -> some View {
        background {
            TraceHoloFrame(active: active, fill: fill).allowsHitTesting(false)
        }
    }
}

struct TraceHoloFrame: View {
    var active = false
    var fill = 0.34

    var body: some View {
        Canvas { ctx, size in
            let r = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
            ctx.fill(Path(r), with: .color(.black.opacity(fill)))
            ctx.stroke(Path(r), with: .color(.white.opacity(active ? 0.34 : 0.13)), lineWidth: 1)
            // 角标：边长取短边的 28%，限在 4…8pt
            let k = min(8, max(4, min(size.width, size.height) * 0.28))
            var corners = Path()
            for (p, dx, dy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                                (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0), (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0)] {
                corners.move(to: CGPoint(x: p.x + dx * k, y: p.y))
                corners.addLine(to: p)
                corners.addLine(to: CGPoint(x: p.x, y: p.y + dy * k))
            }
            ctx.stroke(corners, with: .color(.white.opacity(active ? 0.9 : 0.55)), lineWidth: 1.5)
        }
    }
}
