import Foundation
import simd

// 航线闪电：两站之间不画抛物线，画一道闪电，并从闪电向全国辐射——
//   主干：同一国家、边界网连得通时，从上一站所在的区（没有区级数据就是市，再没有就是最近的边界点）出发，
//         沿区界 / 市界 / 省界 / 国界找到通往下一站所在区的最短路径；连不通（跨国、跨海）就沿大圆生成一道折线闪电。
//   辐射：主干劈过的每一点都是新的起点，光沿边界网传遍这个国家（跨国段在到达的国家里从落点传开）。
//         辐射是一棵最短路径树：被越多远处线段借道的枝越亮（主干感），末梢细弱，整体像闪电的分叉；
//         几秒后末梢熄灭，粗枝留下常亮——闪电的常态是主干带着几条分叉，不是孤零零一根。
//
//   建网：同一国家的所有边界折线，端点与折点按约 1 公里网格合并；不同来源的线（区界 / 省界 / 国界）
//        顶点对不齐，每个点再连到附近别的线上最近的点（折点约 5 公里内，线头约 30 公里内），网才连通。
//   时间：主干 0.55 秒从起点劈到终点（越走越快）；辐射沿线距离 d 公里在 log(1 + d / 12) / 2.3 秒后到达
//        （约 1 秒出市、2.5 秒铺满全国），主干上较晚劈到的点按同一换算折成提前量，波前接得上。
//   输出：线段两端各 8 个数——经度、纬度、亮起时刻（秒）、是否主干、离主干的沿线公里数、下游枝干总长（公里）、
//        离两端站点的直线公里数（站点是视觉焦点：着色器按屏幕像素让站点附近最亮、其余按距离压暗）。
//        分叉的粗细与衰减都不按公里定：着色器按当前缩放把公里换成屏幕像素，再跟画面大小比——
//        放大后同一片区界在屏幕上变长，就变粗变亮，近看远看分叉在画面里的比例一样。
//        各自烘焙 −360 / 0 / +360 三份（与底图同一做法）。闪烁、熄灭都在着色器里按时间算，CPU 只算一次。

/// 着色器读的顶点：经度、纬度、亮起时刻（秒）、是否主干（1 / 0）、离主干公里数、下游枝干总长（公里）、离起点公里数、离终点公里数。
typealias TraceRadVertex = SIMD8<Float>

enum TraceRadiation {
    /// 一个国家的边界网（建一次缓存）。
    private final class Graph {
        var pos: [SIMD2<Float>] = []
        var adj: [[(to: Int32, km: Float)]] = []
        /// 每条输入折线对应的节点序列（区 / 市的环在这里找起点）。
        var lines: [[Int32]] = []
        /// 区、市边界环在 lines 里的下标：(级别, 外环点集, 折线下标)。
        var regions: [(level: Int, ring: [SIMD2<Float>], line: Int)] = []
    }

    private static var cache: [String: Graph] = [:]
    private static let lock = NSLock()

    /// 主干击中用时（秒）。
    static let strike: Float = 0.55

    /// 一道闪电：顶点（成对）。哪些枝常亮、多亮由着色器按当前画面算，所以全部常驻。
    struct Bolt {
        var vertices: [TraceRadVertex]
    }

    static func bolt(from a: (lon: Double, lat: Double, code: String), to b: (lon: Double, lat: Double, code: String)) -> Bolt {
        let pa = SIMD2(Float(a.lon), Float(a.lat)), pb = SIMD2(Float(b.lon), Float(b.lat))
        var main: [TraceRadVertex] = []
        var spread: [TraceRadVertex] = []
        if a.code == b.code, !a.code.isEmpty, let g = graph(a.code), let path = along(g, pa, pb) {
            main = path.vertices
            spread = radiate(g, seeds: path.seeds)
        } else {
            main = synthetic(pa, pb)
            // 跨国 / 跨海：在到达的国家里，主干击中后从落点传开
            if let g = graph(b.code) { spread = radiate(g, seeds: anchor(g, pb).map { ($0, strike) }) }
        }
        // 每个顶点记下离两端站点的直线距离，着色器按屏幕像素定焦点
        var all = main + spread
        for i in all.indices {
            let p = SIMD2(all[i][0], all[i][1])
            all[i][6] = km(p, pa); all[i][7] = km(p, pb)
        }
        return Bolt(vertices: tripled(all))
    }

    private static func mainVertex(_ p: SIMD2<Float>, _ t: Float) -> TraceRadVertex { TraceRadVertex(p.x, p.y, t, 1, 0, 0, 0, 0) }
    /// 分叉顶点：离主干公里数、下游枝干总长（公里）。
    private static func branchVertex(_ p: SIMD2<Float>, _ t: Float, _ fromTrunk: Float, _ downstream: Float) -> TraceRadVertex {
        TraceRadVertex(p.x, p.y, t, 0, max(0, fromTrunk), downstream, 0, 0)
    }

    /// 主干上沿线距离 → 亮起时刻：0.55 秒劈完，越走越快。
    private static func strikeTime(_ d: Float, _ length: Float) -> Float {
        strike * pow(min(1, d / max(1, length)), 1 / 1.6)
    }

    /// 辐射的距离 ↔ 时间换算：沿线 d 公里在 log(1 + d / 12) / 2.3 秒后到达。
    private static func spreadTime(_ d: Float) -> Float { log(1 + d / 12) / 2.3 }
    private static func spreadDistance(_ t: Float) -> Float { 12 * (exp(2.3 * t) - 1) }

    /// 沿边界网的主干：最短路径；返回顶点与路径上各点的亮起时刻（辐射从这里接着传）。
    private static func along(_ g: Graph, _ pa: SIMD2<Float>, _ pb: SIMD2<Float>) -> (vertices: [TraceRadVertex], seeds: [(Int32, Float)])? {
        let src = anchor(g, pa), dst = Set(anchor(g, pb))
        guard !src.isEmpty, !dst.isEmpty else { return nil }
        let n = g.pos.count
        var dist = [Float](repeating: .infinity, count: n)
        var parent = [Int32](repeating: -1, count: n)
        var heap = Heap()
        for s in src { dist[Int(s)] = km(pa, g.pos[Int(s)]); heap.push(dist[Int(s)], s) }
        var hit: Int32 = -1
        while let (d, u) = heap.pop() {
            guard d <= dist[Int(u)] else { continue }
            if dst.contains(u) { hit = u; break }
            for e in g.adj[Int(u)] {
                let nd = d + e.km
                if nd < dist[Int(e.to)] { dist[Int(e.to)] = nd; parent[Int(e.to)] = u; heap.push(nd, e.to) }
            }
        }
        guard hit >= 0 else { return nil }
        var path: [Int32] = []
        var v = hit
        while v >= 0 { path.append(v); v = parent[Int(v)] }
        path.reverse()
        // 绕得太远（超过直线的 4 倍）就不像航线了，改用大圆闪电
        let length = dist[Int(hit)] + km(g.pos[Int(hit)], pb)
        guard length < max(80, km(pa, pb) * 4) else { return nil }

        var out: [TraceRadVertex] = []
        var seeds: [(Int32, Float)] = []
        var prev = pa, d: Float = 0
        for id in path {
            let q = g.pos[Int(id)]
            out.append(mainVertex(prev, strikeTime(d, length)))
            d += km(prev, q)
            out.append(mainVertex(q, strikeTime(d, length)))
            seeds.append((id, strikeTime(d, length)))
            prev = q
        }
        out += [mainVertex(prev, strikeTime(d, length)), mainVertex(pb, strike)]
        return (out, seeds)
    }

    /// 从若干起点（各带亮起时刻）沿边界网传遍整个连通的网：最短路径树，按子树大小定亮度。
    private static func radiate(_ g: Graph, seeds: [(Int32, Float)]) -> [TraceRadVertex] {
        let n = g.pos.count
        var dist = [Float](repeating: .infinity, count: n)
        var parent = [Int32](repeating: -1, count: n)
        /// 所属起点折算的提前量：dist − base = 离主干的沿线距离（亮度按它衰减）。
        var base = [Float](repeating: 0, count: n)
        var heap = Heap()
        // 起点的亮起时刻折成「提前走过的距离」，各起点的波前在同一把尺子上比较
        for (s, t) in seeds {
            let d0 = spreadDistance(t)
            if d0 < dist[Int(s)] { dist[Int(s)] = d0; base[Int(s)] = d0; parent[Int(s)] = -1; heap.push(d0, s) }
        }
        var reached: [Int] = []
        while let (d, u) = heap.pop() {
            guard d <= dist[Int(u)] else { continue }
            reached.append(Int(u))
            for e in g.adj[Int(u)] {
                let nd = d + e.km
                if nd < dist[Int(e.to)] { dist[Int(e.to)] = nd; parent[Int(e.to)] = u; base[Int(e.to)] = base[Int(u)]; heap.push(nd, e.to) }
            }
        }
        // 下游枝干总长：按距离从远到近，把每条边的长度连同子树累加到父节点
        var below = [Float](repeating: 0, count: n)
        for u in reached.reversed() where parent[u] >= 0 {
            below[Int(parent[u])] += below[u] + km(g.pos[u], g.pos[Int(parent[u])])
        }
        var out: [TraceRadVertex] = []
        out.reserveCapacity(reached.count * 2)
        for u in reached where parent[u] >= 0 {
            let p = Int(parent[u])
            // 这条边的粗细 = 它下游（含自身）的总长；离主干的距离与粗细都交给着色器按屏幕像素算
            let down = below[u] + km(g.pos[u], g.pos[p])
            out.append(branchVertex(g.pos[p], spreadTime(dist[p]), dist[p] - base[p], down))
            out.append(branchVertex(g.pos[u], spreadTime(dist[u]), dist[u] - base[u], down))
        }
        return out
    }

    /// 跳点在网上的落脚点：所在的区（2 级）优先，其次市（1 级）的边界环；都没有就取最近的边界点。
    private static func anchor(_ g: Graph, _ p: SIMD2<Float>) -> [Int32] {
        for level in [2, 1] {
            if let r = g.regions.first(where: { $0.level == level && contains($0.ring, p) }) { return g.lines[r.line] }
        }
        var best = Int32(-1), bd = Float.infinity
        for (i, q) in g.pos.enumerated() {
            let d = km(p, q)
            if d < bd { bd = d; best = Int32(i) }
        }
        return best >= 0 ? [best] : []
    }

    /// 连不通时的主干：沿大圆的折线闪电（中点位移，确定性随机，同一段每次形状一样），带几条短分叉。
    private static func synthetic(_ pa: SIMD2<Float>, _ pb: SIMD2<Float>) -> [TraceRadVertex] {
        var rng = SplitMix(seed: UInt64(bitPattern: Int64((pa.x * 1000).rounded()) &* 31 &+ Int64((pb.y * 1000).rounded())))
        let ua = TraceGeoData.unit(pa.x, pa.y), ub = TraceGeoData.unit(pb.x, pb.y)
        let omega = Float(traceAngle(ua, ub))
        func slerp(_ t: Float) -> SIMD3<Float> {
            guard omega > 1e-5 else { return ua }
            return ua * (sin((1 - t) * omega) / sin(omega)) + ub * (sin(t * omega) / sin(omega))
        }
        func ll(_ v: SIMD3<Float>) -> SIMD2<Float> { SIMD2(atan2(v.y, v.x) * 180 / .pi, asin(max(-1, min(1, v.z))) * 180 / .pi) }
        // 中点位移：每层把每段从中间往法向推一下，幅度逐层减半
        var pts: [(t: Float, off: Float)] = [(0, 0), (1, 0)]
        var amp: Float = 0.08
        for _ in 0..<6 {
            var next: [(Float, Float)] = []
            for k in 0..<pts.count - 1 {
                let a = pts[k], b = pts[k + 1]
                next.append(a)
                next.append(((a.t + b.t) / 2, (a.off + b.off) / 2 + (rng.unit() * 2 - 1) * amp))
            }
            next.append(pts[pts.count - 1]); pts = next; amp *= 0.55
        }
        let normal = simd_normalize(simd_cross(ua, ub))
        func point(_ t: Float, _ off: Float) -> SIMD2<Float> { ll(simd_normalize(slerp(t) + normal * (off * omega))) }
        var geo = pts.map { point($0.t, $0.off) }
        // 经度连续（不跳 ±180）
        for k in 1..<geo.count { while geo[k].x - geo[k - 1].x > 180 { geo[k].x -= 360 }; while geo[k - 1].x - geo[k].x > 180 { geo[k].x += 360 } }
        var cum: [Float] = [0]
        for k in 1..<geo.count { cum.append(cum[k - 1] + km(geo[k - 1], geo[k])) }
        let length = cum.last ?? 0
        var out: [TraceRadVertex] = []
        for k in 1..<geo.count {
            out += [mainVertex(geo[k - 1], strikeTime(cum[k - 1], length)), mainVertex(geo[k], strikeTime(cum[k], length))]
        }
        // 分叉：从主干随机几处岔出去，每条几折、越走越暗（亮度 < 1，随辐射一起熄灭）
        for _ in 0..<6 {
            let k = Int(rng.unit() * Float(geo.count - 2)) + 1
            var p = geo[k], t = strikeTime(cum[k], length)
            let dir = simd_normalize(geo[min(k + 1, geo.count - 1)] - geo[k - 1])
            let side: Float = rng.unit() < 0.5 ? -1 : 1
            let step = length * 0.03
            var from: Float = 0
            for j in 0..<4 {
                let turn = SIMD2(-dir.y, dir.x) * side * (0.4 + rng.unit() * 0.8) + dir * (0.3 + rng.unit() * 0.7)
                let q = p + turn * (step / 111)
                let t2 = t + 0.04, down = Float(4 - j) * step
                out += [branchVertex(p, t, from, down), branchVertex(q, t2, from + step, down)]
                p = q; t = t2; from += step
            }
        }
        return out
    }

    private static func tripled(_ v: [TraceRadVertex]) -> [TraceRadVertex] {
        var all: [TraceRadVertex] = []
        all.reserveCapacity(v.count * 3)
        for shift: Float in [-360, 0, 360] { all += v.map { var c = $0; c[0] += shift; return c } }
        return all
    }

    private struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func unit() -> Float {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Float((z ^ (z >> 31)) >> 40) / Float(1 << 24)
        }
    }

    // MARK: 建网

    private static func graph(_ code: String) -> Graph? {
        lock.lock(); defer { lock.unlock() }
        if let g = cache[code] { return g }
        let geo = TraceGeoData.shared
        var polylines: [(pts: [SIMD2<Float>], closed: Bool)] = []
        for c in geo.countries where c.code == code {
            for r in c.fine { polylines.append((pts: r.lonLat, closed: true)) }
        }
        guard !polylines.isEmpty else { return nil }
        for r in geo.provincesByCountry[code] ?? [] { polylines.append((pts: r.lonLat, closed: false)) }
        let regionStart = polylines.count
        let regs = geo.regions.filter { $0.code == code }
        var regionLines: [(Int, [SIMD2<Float>], Int)] = []
        for r in regs {
            for ring in r.rings {
                regionLines.append((r.level, ring, polylines.count - regionStart))
                polylines.append((pts: ring, closed: true))
            }
        }

        let g = Graph()
        // 约 1 公里的网格合并重合点
        var snap: [Int64: Int32] = [:]
        func key(_ p: SIMD2<Float>, _ cell: Float) -> Int64 {
            Int64((p.x / cell).rounded(.down)) &* 1_000_003 &+ Int64((p.y / cell).rounded(.down))
        }
        func node(_ p: SIMD2<Float>) -> Int32 {
            let k = key(p, 0.01)
            if let i = snap[k] { return i }
            let i = Int32(g.pos.count)
            g.pos.append(p); g.adj.append([]); snap[k] = i
            return i
        }
        func link(_ a: Int32, _ b: Int32) {
            guard a != b else { return }
            let d = km(g.pos[Int(a)], g.pos[Int(b)])
            g.adj[Int(a)].append((b, d)); g.adj[Int(b)].append((a, d))
        }
        var lineOf: [Int32] = []
        for (li, pl) in polylines.enumerated() {
            var ids = pl.pts.map { node($0) }
            if pl.closed, let f = ids.first { ids.append(f) }
            var dedup: [Int32] = []
            for i in ids where dedup.last != i { dedup.append(i) }
            for k in 1..<max(1, dedup.count) { link(dedup[k - 1], dedup[k]) }
            g.lines.append(dedup)
            while lineOf.count < g.pos.count { lineOf.append(Int32(li)) }
        }
        g.regions = regionLines.map { ($0.0, $0.1, $0.2 + regionStart) }

        // 跨线连接：每点连到附近别的线上最近的点（折点 0.05°、线头 0.3°）
        let cell: Float = 0.3
        var grid: [Int64: [Int32]] = [:]
        for (i, p) in g.pos.enumerated() { grid[key(p, cell), default: []].append(Int32(i)) }
        for (i, p) in g.pos.enumerated() {
            let reach: Float = g.adj[i].count <= 1 ? 0.3 : 0.05
            let cx = Int64((p.x / cell).rounded(.down)), cy = Int64((p.y / cell).rounded(.down))
            var best = Int32(-1), bd = reach * reach
            for dx in -1...1 {
                for dy in -1...1 {
                    for j in grid[(cx + Int64(dx)) &* 1_000_003 &+ (cy + Int64(dy))] ?? [] where lineOf[Int(j)] != lineOf[i] {
                        let q = g.pos[Int(j)], d2 = simd_length_squared(q - p)
                        if d2 < bd { bd = d2; best = j }
                    }
                }
            }
            if best >= 0 { link(Int32(i), best) }
        }
        cache[code] = g
        return g
    }

    // MARK: 工具

    private static func km(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let c = cos((a.y + b.y) / 2 * .pi / 180)
        return hypot((a.x - b.x) * c, a.y - b.y) * 111.2
    }

    private static func contains(_ ring: [SIMD2<Float>], _ p: SIMD2<Float>) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in 0..<ring.count {
            let a = ring[i], b = ring[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// 最小堆（距离, 节点）。
    private struct Heap {
        private var a: [(Float, Int32)] = []
        mutating func push(_ d: Float, _ v: Int32) {
            a.append((d, v))
            var i = a.count - 1
            while i > 0 {
                let p = (i - 1) / 2
                guard a[p].0 > a[i].0 else { break }
                a.swapAt(p, i); i = p
            }
        }
        mutating func pop() -> (Float, Int32)? {
            guard let top = a.first else { return nil }
            let last = a.removeLast()
            if !a.isEmpty {
                a[0] = last
                var i = 0
                while true {
                    let l = 2 * i + 1, r = l + 1
                    var m = i
                    if l < a.count, a[l].0 < a[m].0 { m = l }
                    if r < a.count, a[r].0 < a[m].0 { m = r }
                    if m == i { break }
                    a.swapAt(i, m); i = m
                }
            }
            return top
        }
    }
}
