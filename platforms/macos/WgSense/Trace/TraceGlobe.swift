import SwiftUI
import simd

// 地球相机与投影：缩小是可任意旋转的地球（正射投影），放大过程中球面逐渐展平成以视野中心为准的方位等距平面地图，
// 中间没有切换的那一下（形态系数 morph 随缩放连续变化）。航线、标注、底图都走这一个投影。

/// 相机：视野中心经纬度 + 缩放（地球半径 / 画幅短边的一半；0.9 ≈ 整个地球）。
struct TraceCam: Equatable {
    var lon: Double
    var lat: Double
    var zoom: Double

    /// 待机视角：整个地球，朝向最近学到的本网络出口；没有记录就按系统时区推经度。
    static var idle: TraceCam {
        if let data = UserDefaults.standard.data(forKey: "trace.origins"),
           let map = try? JSONDecoder().decode([String: TraceOrigin].self, from: data),
           let o = map.values.max(by: { $0.learnedAt < $1.learnedAt }) {
            return TraceCam(lon: o.geo.lon, lat: min(50, max(-30, o.geo.lat)), zoom: 0.9)
        }
        return TraceCam(lon: Double(TimeZone.current.secondsFromGMT()) / 240, lat: 20, zoom: 0.9)
    }

    /// 开场终点：待机视角推近到地球直径约为可见区域短边的 1.2 倍（上下溢出画幅，只露一片区域），仍是地球形态。
    static var introEnd: TraceCam { var c = idle; c.zoom = 1.2; return c }
    /// 开场起点：完整地球、约半屏大小，朝向与终点错开 60° 经度，开场时一边转一边推近。
    static var introStart: TraceCam { var c = idle; c.lon -= 60; c.lat = max(-20, c.lat - 15); c.zoom = 0.55; return c.clamped() }

    static let minZoom = 0.5
    /// 区县级：一屏约 0.3° 经度（东京的区、深圳的区分得开）。
    static let maxZoom = 400.0

    /// 0 = 地球，1 = 平面。
    /// 展平放在放大后段（一屏约 ±10° → ±4°）：这时球面与平面只差千分之几，看不出转变（MapLibre 也是放到城市级才切平面）。
    var morph: Double {
        let x = min(1, max(0, (zoom - 6) / (16 - 6)))
        return x * x * (3 - 2 * x)
    }

    var center: SIMD3<Float> { TraceGeoData.unit(Float(lon), Float(lat)) }

    func clamped() -> TraceCam {
        var c = self
        c.zoom = min(Self.maxZoom, max(Self.minZoom, zoom))
        c.lat = min(80, max(-80, lat))
        c.lon = (lon + 540).truncatingRemainder(dividingBy: 360) - 180
        return c
    }

    /// 拖动：屏幕位移换算成经纬度（与 MapLibre 地球模式同一做法：北始终朝上，不做「抓住地面」）。
    /// 横向按 1/cos(纬度) 加速，靠近两极时画面也跟得上手；缩小看地球时按纬度 60° 封顶（极区不至于转得太猛），
    /// 放大过程中按缩放的对数逐渐放开封顶（MapLibre 是缩放级别 3 → 7，折算到这里约 2.5 → 40）。
    func dragged(dx: Double, dy: Double, minSide: Double) -> TraceCam {
        let v = angularVelocity(vx: dx, vy: dy, minSide: minSide)
        return TraceCam(lon: lon + v.lon, lat: lat + v.lat, zoom: zoom).clamped()
    }

    /// 拖动速度（点/秒）换算成角速度（°/s），与 dragged 同一套比例。
    func angularVelocity(vx: Double, vy: Double, minSide: Double) -> (lon: Double, lat: Double) {
        let r = zoom * minSide / 2
        return (-vx / r * 180 / .pi * lonSpeed, vy / r * 180 / .pi)
    }

    /// 横向速度系数：1/cos(纬度)，按缩放在「纬度封顶 60°」与「不封顶」之间插值。
    var lonSpeed: Double {
        let capped = 1 / cos(min(abs(lat), 60) * .pi / 180)
        let full = 1 / max(0.1, cos(lat * .pi / 180))
        let w = min(1, max(0, log2(zoom / 2.5) / 4))
        return capped + (full - capped) * w
    }

    /// 框住一组坐标：中心取球面平均，缩放让最远一点落在画幅约 40% 半径处；跨半球以上就是整个地球。
    static func fit(_ coords: [(lon: Double, lat: Double)]) -> TraceCam? {
        guard !coords.isEmpty else { return nil }
        let vs = coords.map { TraceGeoData.unit(Float($0.lon), Float($0.lat)) }
        let sum = vs.reduce(SIMD3<Float>.zero, +)
        let c = simd_length(sum) > 1e-4 ? simd_normalize(sum) : vs[0]
        var reach = 0.0
        for v in vs { reach = max(reach, traceAngle(v, c)) }
        // 单点：给一个区域视野（约 12°）
        let angle = max(reach, 0.1)
        let zoom = angle > 1.2 ? 0.9 : 0.8 / sin(angle)
        let lat = Double(asin(c.z)) * 180 / .pi, lon = Double(atan2(c.y, c.x)) * 180 / .pi
        return TraceCam(lon: lon, lat: lat, zoom: zoom).clamped()
    }
}

/// 两个单位向量的夹角（弧度）。
func traceAngle(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Double {
    let d: Float = min(1, max(-1, simd_dot(a, b)))
    return Double(acos(d))
}

/// 镜头：三种运动叠在一起，任何时刻都由时间算出，不依赖 SwiftUI 动画——
///   飞行：中心沿大圆走，缩放按对数插值，两点相距远时中途先拉高再落下（像飞行地图）；
///   惯性：拖动松手后按松手速度继续滑，指数衰减；
///   自转：待机或手动停手一阵后，地球缓慢向东转（只在地球形态下）。
struct TraceFlight {
    static let duration: TimeInterval = 1.4
    /// 惯性衰减时间常数：约 3 倍后基本停住。
    static let inertia: TimeInterval = 0.6
    /// 自转速度（°/s）：约两分钟一圈。
    static let spinSpeed = 3.0
    /// 停手多久后开始自转。
    static let spinDelay: TimeInterval = 4
    /// 放大到这个程度以上不自转（近景转起来又快又晕）。
    static let spinMaxZoom = 1.6
    /// 前台待机时转多久后开始缓停（省电：转着就要按屏幕刷新一直画）。
    static let spinRun: TimeInterval = 60
    /// 缓停时长：速度按 (1 − x)³ 非线性降到 0，起步减得快、末尾拖得长，停得没有顿挫。
    static let spinEase: TimeInterval = 5
    /// 起转时长：速度按 1 − (1 − x)³ 从 0 加到全速（和缓停对称），不会一下子转起来。
    static let spinRamp: TimeInterval = 5

    var from: TraceCam
    var to: TraceCam
    var at = Date.distantPast
    /// 本次飞行时长（开场动画比普通跟拍慢）。
    var span: TimeInterval = TraceFlight.duration
    /// 惯性：松手时的角速度（°/s）。
    var fling: (lon: Double, lat: Double, at: Date)?
    /// 自转起点；nil = 不自转。可以在将来（先等停手延迟）。
    var spinFrom: Date?
    /// 开始缓停的时刻；之后 spinEase 秒内速度降到 0，然后静止。nil = 一直转。
    var spinStop: Date?
    /// 滑行（缩放惯性、滚轮）：from → to 按指数缓停，越来越慢地贴近终点，没有起步加速；nil = 普通飞行。
    var glideTau: TimeInterval?
    /// 滑行的时间常数：约 5 倍后到位。
    static let glide: TimeInterval = 0.12

    init(_ cam: TraceCam) { from = cam; to = cam }

    func cam(at now: Date) -> TraceCam {
        var c = flown(at: now)
        if let f = fling {
            let k = Self.inertia * (1 - exp(-max(0, now.timeIntervalSince(f.at)) / Self.inertia))
            c.lon += f.lon * k
            c.lat += f.lat * k
        }
        if let s = spinFrom, now > s, c.zoom < Self.spinMaxZoom {
            c.lon += Self.spinAngle(from: s, stop: spinStop, now: now)
        }
        return c.clamped()
    }

    private func flown(at now: Date) -> TraceCam {
        let p = min(1, max(0, now.timeIntervalSince(at) / span))
        guard p < 1 else { return to }
        if let tau = glideTau {
            // 指数缓停（按 5τ 归一，末端正好到位）；中途不拉远
            let t = now.timeIntervalSince(at)
            let e = (1 - exp(-t / tau)) / (1 - exp(-5))
            return interpolate(e, lift: false)
        }
        let e = p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2
        return interpolate(e, lift: true)
    }

    /// from → to 的中间画面：中心沿大圆插值，缩放按对数插值；lift = 中途拉远一点（长距离飞行用）。
    private func interpolate(_ e: Double, lift useLift: Bool) -> TraceCam {
        let a = from.center, b = to.center
        let omega = traceAngle(a, b)
        var v = b
        if omega > 1e-4 {
            let s = sin(omega)
            v = a * Float(sin((1 - e) * omega) / s) + b * Float(sin(e * omega) / s)
        }
        // 中途拉远的幅度：起点或终点本来就是小地球（如开场）时不再往外拉，一路推近
        let lift = useLift ? log(1 + omega * 2) * 0.9 * min(1, from.zoom, to.zoom) : 0
        let z = exp(log(from.zoom) + (log(to.zoom) - log(from.zoom)) * e - lift * sin(.pi * e))
        return TraceCam(lon: Double(atan2(v.y, v.x)) * 180 / .pi, lat: Double(asin(v.z)) * 180 / .pi, zoom: z).clamped()
    }

    /// 自转转过的经度：速度 = 全速 × 起转系数 × 缓停系数（起转 1 − (1 − x)³ 从 0 加到 1，缓停 (1 − x)³ 从 1 降到 0），
    /// 对时间积分。两段互不重叠时用解析式；缓停落在起转途中（刚起转就失焦）时这一段数值积分。
    private static func spinAngle(from s: Date, stop: Date?, now: Date) -> Double {
        let t = now.timeIntervalSince(s)
        let R = spinRamp, D = spinEase
        let run = stop.map { max(0, $0.timeIntervalSince(s)) } ?? .infinity
        // 起转段 ∫(1 − (1 − τ/R)³)：到 τ 为 τ − R(1 − (1 − τ/R)⁴)/4
        func ramp(_ τ: Double) -> Double { let x = min(1, τ / R); return min(τ, R) - R * (1 - pow(1 - x, 4)) / 4 }
        if run >= R {
            if t <= run { return spinSpeed * (ramp(t) + max(0, t - R)) }
            let x = min(1, (t - run) / D)
            return spinSpeed * (ramp(R) + (run - R) + D * (1 - pow(1 - x, 4)) / 4)
        }
        // 起转没完就开始缓停：速度连续，按小步数值积分（只在这几秒里发生）
        let end = min(t, run + D)
        let n = 48
        var sum = 0.0
        for k in 0..<n {
            let τ = (Double(k) + 0.5) / Double(n) * end
            let up = 1 - pow(1 - min(1, τ / R), 3)
            let down = τ < run ? 1 : pow(max(0, 1 - (τ - run) / D), 3)
            sum += up * down
        }
        return spinSpeed * sum * end / Double(n)
    }

    /// 自转还在动（没开始缓停，或缓停未结束）。
    private func spinning(_ now: Date) -> Bool {
        guard let s = spinFrom, to.zoom < Self.spinMaxZoom else { return false }
        guard let stop = spinStop else { return true }
        return now < max(s, stop).addingTimeInterval(Self.spinEase)
    }

    /// 飞行或惯性滑行中：需要满帧。
    var fastMoving: Bool {
        let now = Date()
        if now.timeIntervalSince(at) < span { return true }
        if let f = fling, now.timeIntervalSince(f.at) < Self.inertia * 5 { return true }
        return false
    }

    /// 画面是否还在动（决定要不要按屏幕刷新推进）。
    var moving: Bool {
        let now = Date()
        if now.timeIntervalSince(at) < span { return true }
        if let f = fling, now.timeIntervalSince(f.at) < Self.inertia * 5 { return true }
        return spinning(now)
    }

    /// 把当前画面定格成静止起点（惯性、自转都折进去）。
    private mutating func settle(_ now: Date) {
        let c = cam(at: now)
        from = c; to = c; at = .distantPast; fling = nil; spinFrom = nil; spinStop = nil
    }

    mutating func fly(to next: TraceCam, span: TimeInterval = TraceFlight.duration) {
        let now = Date()
        let c = cam(at: now)
        from = c; to = next; at = now; self.span = span; fling = nil; spinFrom = nil; spinStop = nil; glideTau = nil
    }

    /// 滑到 next：从当前画面出发、指数缓停（缩放惯性、滚轮用）。连续调用时从当时的画面接着滑，不跳。
    mutating func glide(to next: TraceCam, tau: TimeInterval = TraceFlight.glide) {
        let c = cam(at: Date())
        from = c; to = next; at = Date(); span = tau * 5; fling = nil; spinFrom = nil; spinStop = nil; glideTau = tau
    }

    /// 手势跟手：直接到位，停掉惯性与自转。
    mutating func jump(to v: TraceCam) { from = v; to = v; at = .distantPast; fling = nil; spinFrom = nil; spinStop = nil; glideTau = nil }

    /// 拖动松手：按松手速度滑出去。
    mutating func release(lon: Double, lat: Double) {
        let now = Date()
        settle(now)
        // 太快的甩动限一下速，免得一甩转好几圈；经度总滑动量（速度 × 时间常数）还要低于半圈，
        // 否则看起来像往反方向转（MapLibre 限在 179.5°）
        let cap = 240.0, lonCap = min(cap, 179.5 / Self.inertia)
        fling = (max(-lonCap, min(lonCap, lon)), max(-cap, min(cap, lat)), now)
    }

    /// 允许 / 禁止自转。允许时等停手延迟（或当前飞行结束）后再开始；禁止时定格在当前画面。
    mutating func setSpin(_ on: Bool) {
        let now = Date()
        if on {
            guard spinFrom == nil else { return }
            let flightEnd = at.addingTimeInterval(span)
            let start = max(now, flightEnd).addingTimeInterval(Self.spinDelay)
            spinFrom = start
            // 前台待机也只转一阵：到点缓停
            spinStop = start.addingTimeInterval(Self.spinRun)
        } else if let s = spinFrom {
            if now > s { settle(now) } else { spinFrom = nil; spinStop = nil }
        }
    }

    /// 现在就开始缓停（窗口失去焦点）；还没开始转的直接取消。
    mutating func easeSpinToStop() {
        let now = Date()
        guard let s = spinFrom else { return }
        if now <= s { spinFrom = nil; spinStop = nil; return }
        if let stop = spinStop, stop <= now { return }
        spinStop = now
    }

    /// 重新开始一轮自转（窗口回到焦点）：先把已转过的角度定格，再从现在起转一阵、到点缓停。
    mutating func restartSpin(delay: TimeInterval = 0.5) {
        let now = Date()
        let flightEnd = at.addingTimeInterval(span)
        if now < flightEnd || fling != nil || (spinFrom.map { now <= $0 } ?? false) {
            // 正在飞行 / 滑行 / 惯性（比如开场推近），或还没开始转：只预约起转，不定格画面——
            // 定格会把开场动画截停在半路，地球停在偏小的大小
            spinFrom = max(now, flightEnd).addingTimeInterval(delay)
        } else {
            // 已经转过（或缓停完）：把转过的角度定格，再从现在起转
            if spinFrom != nil { settle(now) }
            spinFrom = now.addingTimeInterval(delay)
        }
        spinStop = spinFrom!.addingTimeInterval(Self.spinRun)
    }
}

/// 投影：给定相机与画幅，把球面点 / 经纬度投到屏幕。
struct TraceGlobeProjection {
    let cam: TraceCam
    let size: CGSize
    /// 地球半径（点）。
    let radius: Double
    let origin: CGPoint
    let morph: Double
    private let east, north, forward: SIMD3<Float>

    /// shift：地球中心相对画幅中心的偏移（全息模式下画幅是整个窗口，地球对准侧栏右边、顶部浮层以下的区域），也决定地球大小的基准。
    /// pan：用户挪动视图的位移，只挪位置、不改大小。
    init(cam: TraceCam, size: CGSize, shift: CGSize = .zero, pan: CGSize = .zero) {
        self.cam = cam
        self.size = size
        radius = cam.zoom * Self.side(size, shift) / 2
        origin = CGPoint(x: size.width / 2 + shift.width + pan.width, y: size.height / 2 + shift.height + pan.height)
        morph = cam.morph
        forward = cam.center
        let l = Float(cam.lon * .pi / 180)
        east = SIMD3(-sin(l), cos(l), 0)
        north = simd_cross(forward, east)
    }

    /// 地球大小的基准：可见区域（画幅减去两侧偏移，即侧栏右边、顶部浮层以下）的短边。
    static func side(_ size: CGSize, _ shift: CGSize) -> Double {
        Double(max(1, min(size.width - 2 * abs(shift.width), size.height - 2 * abs(shift.height))))
    }

    /// 视野角半径（弧度）：超出这个范围的环直接跳过。
    var reach: Float {
        let halfDiag = Double(hypot(size.width, size.height)) / 2
        return Float(min(Double.pi / 2 + 0.15, halfDiag / radius * 1.25 + 0.05))
    }

    func inView(_ ring: TraceGeoRing) -> Bool {
        Float(traceAngle(ring.center, forward)) - ring.radius < reach
    }

    /// 投一个点。alt 为离地高度（地球半径的倍数，航线拱起用）；refLon 已不需要（方位投影没有 ±180 的跳变），保留参数免改调用方。
    func project(_ p: SIMD3<Float>, lon: Double, lat: Double, alt: Double = 0, refLon: inout SIMD2<Double>?) -> (CGPoint, Bool) {
        let x = Double(simd_dot(p, east)), y = Double(simd_dot(p, north)), z = Double(simd_dot(p, forward))
        let s = 1 + alt
        var sx = x * s, sy = y * s
        var visible = z > 0 || (alt > 0 && (x * x + y * y) * s * s > 1)
        if !visible {
            // 背面的点压到地平线上：跨地平线的面不会翻到正面来
            let l = hypot(x, y)
            if l > 1e-9 { sx = x / l; sy = y / l }
        }
        // 平面：以视野中心为准的方位等距（方向同球面，距离 = 角距），与 GPU 底图同一公式，展平只是径向伸缩
        // 角距用 atan2（小角度时 acos 精度差，放大后会抖）
        let l = hypot(x, y), c = atan2(l, z)
        let k = l > 1e-12 ? c / l : 1
        let px = x * k, py = y * k + alt * 0.35
        let m = morph
        if m > 0.5 { visible = true }
        let X = sx + (px - sx) * m, Y = sy + (py - sy) * m
        return (CGPoint(x: origin.x + X * radius, y: origin.y - Y * radius), visible)
    }

    func project(lon: Double, lat: Double, alt: Double = 0) -> (CGPoint, Bool) {
        var ref: SIMD2<Double>?
        return project(TraceGeoData.unit(Float(lon), Float(lat)), lon: lon, lat: lat, alt: alt, refLon: &ref)
    }

    /// 闭合环（陆地）：在地平线处切开。fill 里背面那段换成沿地平线走的弧；border 只画正面的边，背面断开。
    /// 完全展平后不再切（背面在平面形态下本来就在画面外）。
    func addRing(_ ring: TraceGeoRing, fill: inout Path, border: inout Path?, alt: Double = 0) {
        let n = ring.points.count
        guard n >= 3 else { return }
        var ref: SIMD2<Double>?
        func proj(_ v: SIMD3<Float>) -> CGPoint {
            let lat = Double(asin(min(1, max(-1, v.z)))) * 180 / .pi, lon = Double(atan2(v.y, v.x)) * 180 / .pi
            return project(v, lon: lon, lat: lat, alt: alt, refLon: &ref).0
        }
        func projAt(_ i: Int) -> CGPoint {
            let ll = ring.lonLat[i]
            return project(ring.points[i], lon: Double(ll.x), lat: Double(ll.y), alt: alt, refLon: &ref).0
        }
        if morph >= 0.999 {
            for i in 0..<n { let pt = projAt(i); if i == 0 { fill.move(to: pt) } else { fill.addLine(to: pt) } }
            fill.closeSubpath()
            if border != nil {
                ref = nil
                for i in 0..<n { let pt = projAt(i); if i == 0 { border!.move(to: pt) } else { border!.addLine(to: pt) } }
                border!.closeSubpath()
            }
            return
        }
        let z = ring.points.map { simd_dot($0, forward) }
        // 从一个正面的点开始走一圈；没有正面的点整环跳过
        guard let start = z.firstIndex(where: { $0 > 0 }) else { return }
        var started = false
        var exitAngle: Double?
        var pen = false
        func horizonPoint(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ za: Float, _ zb: Float) -> SIMD3<Float> {
            let t = za / (za - zb)
            let v = a + (b - a) * t
            let h = v - forward * simd_dot(v, forward)
            return simd_length(h) > 1e-6 ? simd_normalize(h) : a
        }
        func angleOf(_ v: SIMD3<Float>) -> Double { atan2(Double(simd_dot(v, north)), Double(simd_dot(v, east))) }
        func horizonAt(_ th: Double) -> SIMD3<Float> { east * Float(cos(th)) + north * Float(sin(th)) }
        func addFill(_ pt: CGPoint) { if started { fill.addLine(to: pt) } else { fill.move(to: pt); started = true } }
        func addBorder(_ pt: CGPoint, newRun: Bool) {
            guard border != nil else { return }
            if newRun || !pen { border!.move(to: pt) } else { border!.addLine(to: pt) }
            pen = true
        }
        for k in 0...n {
            let i = (start + k) % n, j = (start + k + 1) % n
            if z[i] > 0 {
                let pt = projAt(i)
                addFill(pt)
                if k < n || pen { addBorder(pt, newRun: false) }
            }
            guard k < n else { break }
            if (z[i] > 0) != (z[j] > 0) {
                let h = horizonPoint(ring.points[i], ring.points[j], z[i], z[j])
                if z[i] > 0 {
                    // 离开正面：记下出口角度，描边断开
                    let pt = proj(h)
                    addFill(pt); addBorder(pt, newRun: false)
                    pen = false
                    exitAngle = angleOf(h)
                } else {
                    // 回到正面：沿地平线从出口走到入口（取短的一侧），再接上
                    let entry = angleOf(h)
                    if let ex = exitAngle {
                        var d = entry - ex
                        while d > .pi { d -= 2 * .pi }
                        while d < -.pi { d += 2 * .pi }
                        let steps = max(1, Int(abs(d) / (5 * .pi / 180)))
                        for s in 1..<steps { addFill(proj(horizonAt(ex + d * Double(s) / Double(steps)))) }
                    }
                    let pt = proj(h)
                    addFill(pt); addBorder(pt, newRun: true)
                    exitAngle = nil
                }
            }
        }
        fill.closeSubpath()
    }

    /// 折线（边界、经纬网）：背面的段断开不画。
    func addLine(_ pts: [SIMD3<Float>], lonLat: [SIMD2<Float>], to path: inout Path) {
        var ref: SIMD2<Double>?
        var pen = false
        for (i, p) in pts.enumerated() {
            let ll = lonLat[i]
            let (pt, v) = project(p, lon: Double(ll.x), lat: Double(ll.y), refLon: &ref)
            if v { if pen { path.addLine(to: pt) } else { path.move(to: pt) } }
            pen = v
        }
    }

    /// 两点间的大圆弧（拱起）：返回采样点与可见性。
    func arc(from a: (lon: Double, lat: Double), to b: (lon: Double, lat: Double), samples: Int = 64) -> [(CGPoint, Bool)] {
        let va = TraceGeoData.unit(Float(a.lon), Float(a.lat)), vb = TraceGeoData.unit(Float(b.lon), Float(b.lat))
        let omega = traceAngle(va, vb)
        let peak = min(0.35, omega * 0.22)
        var ref: SIMD2<Double>?
        return (0...samples).map { i in
            let t = Double(i) / Double(samples)
            var v = vb
            if omega > 1e-5 {
                let s = sin(omega)
                v = va * Float(sin((1 - t) * omega) / s) + vb * Float(sin(t * omega) / s)
            }
            let lat = Double(asin(v.z)) * 180 / .pi, lon = Double(atan2(v.y, v.x)) * 180 / .pi
            return project(v, lon: lon, lat: lat, alt: peak * sin(.pi * t), refLon: &ref)
        }
    }
}
