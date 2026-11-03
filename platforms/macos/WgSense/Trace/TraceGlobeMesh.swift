import Foundation
import simd

// GPU 地图的网格数据（渲染见 TraceMetalMap.swift）：海面、经纬网、陆地、省界、国界都是常驻显存的网格，顶点只存经纬度。
// 球面 ↔ 平面的展平在顶点着色器里做：每个点同时算出正射球面位置与方位等距平面位置，按展平系数插值——
// 和 TraceGlobeProjection 同一套公式，所以 CPU 画的航线、标注照样对得上。每帧 CPU 只交几个数（中心经纬度、展平系数）。
//
//   跨日界线：网格按经度 −360 / 0 / +360 烘焙三份；片元着色器只留离视野中心经度 ±180° 以内的那份，
//            三份正好拼成一整圈，不重叠、也没有接缝（地球形态下切口在背面）。
//   贴着球面：三角形与线段都细分到边长 ≤ 3° / 1°，平面三角形的弦不会沉到球面以下被海面挡住。
//   层次：各层离地抬一点点（海面 0、经纬网 0.0005、陆地 0.001、区县界 0.0012、市界 0.0013、省界 0.0015、国界 0.002），靠深度排先后。

enum TraceGlobeMesh {
    /// 网格数据（经纬度，已烘焙三份副本）：首次用到时在后台生成。
    struct Mesh {
        var ocean: [SIMD2<Float>] = [], oceanIdx: [UInt32] = []
        var land: [SIMD2<Float>] = []
        var borders: [SIMD2<Float>] = []
        var provinces: [SIMD2<Float>] = []
        /// 重点地区的市 / 县界与区县界：分两档，放大到不同程度才渐显。
        var cities: [SIMD2<Float>] = []
        var districts: [SIMD2<Float>] = []
        /// 精细陆地块：填色与轮廓（海岸 + 块内省界 / 国界），只在块内画；块内底图的粗陆地、国界、省界不画。
        var fineLand: [SIMD2<Float>] = []
        var fineBorders: [SIMD2<Float>] = []
        var fineWater: [SIMD2<Float>] = []
        var fineIslands: [SIMD2<Float>] = []
        /// 各块的矩形（西、南、东、北）。
        var patches: [SIMD4<Float>] = []
        /// 经纬网：按间距分档（30 / 15 / 5 / 2°），随缩放只显示一档。
        var grids: [Double: [SIMD2<Float>]] = [:]
    }

    static let shared: Mesh = build()

    static let gridSteps: [Double] = [30, 15, 5, 2]

    private static func build() -> Mesh {
        var d = Mesh()
        let geo = TraceGeoData.shared
        let copies: [Float] = [-360, 0, 360]

        // 海面：2° 经纬格，覆盖 −180…180（三份副本拼成 −540…540）
        let step: Float = 2
        let cols = Int(360 / step), rows = Int(180 / step)
        for k in copies {
            let base = UInt32(d.ocean.count)
            for j in 0...rows {
                for i in 0...cols { d.ocean.append(SIMD2(-180 + Float(i) * step + k, -90 + Float(j) * step)) }
            }
            let row = UInt32(cols + 1)
            for j in 0..<UInt32(rows) {
                for i in 0..<UInt32(cols) {
                    let a = base + j * row + i, b = a + 1, c = a + row, e = c + 1
                    d.oceanIdx += [a, b, c, b, e, c]
                }
            }
        }

        // 陆地：每个环耳切剖分，长边细分到 ≤ 3°
        var land: [SIMD2<Float>] = []
        for c in geo.countries {
            for ring in c.fine {
                let pts = ring.lonLat.map { SIMD2<Double>(Double($0.x), Double($0.y)) }
                let t = TraceEarcut.triangulate(pts)
                var i = 0
                while i + 2 < t.count {
                    subdivide(ring.lonLat[t[i]], ring.lonLat[t[i + 1]], ring.lonLat[t[i + 2]], maxEdge: 3, into: &land)
                    i += 3
                }
            }
        }
        for k in copies { d.land += land.map { SIMD2($0.x + k, $0.y) } }

        // 线：相邻两点一段，长段细分到 ≤ 1°
        func lines(_ polylines: [[SIMD2<Float>]], closed: Bool) -> [SIMD2<Float>] {
            var out: [SIMD2<Float>] = []
            for l in polylines where l.count >= 2 {
                let n = closed ? l.count : l.count - 1
                for s in 0..<n { segment(l[s], l[(s + 1) % l.count], maxLen: 1, into: &out) }
            }
            var all: [SIMD2<Float>] = []
            for k in copies { all += out.map { SIMD2($0.x + k, $0.y) } }
            return all
        }
        d.borders = lines(geo.countries.flatMap { c in c.fine.map { $0.lonLat } }, closed: true)
        d.provinces = lines(geo.provinces.map { $0.lonLat }, closed: false)
        d.cities = lines(geo.regions.filter { $0.level == 1 }.flatMap { $0.rings }, closed: true)
        d.districts = lines(geo.regions.filter { $0.level == 2 }.flatMap { $0.rings }, closed: true)
        func fill(_ rings: [[SIMD2<Float>]]) -> [SIMD2<Float>] {
            var tri: [SIMD2<Float>] = []
            for ring in rings {
                let t = TraceEarcut.triangulate(ring.map { SIMD2<Double>(Double($0.x), Double($0.y)) })
                var i = 0
                while i + 2 < t.count {
                    subdivide(ring[t[i]], ring[t[i + 1]], ring[t[i + 2]], maxEdge: 3, into: &tri)
                    i += 3
                }
            }
            var all: [SIMD2<Float>] = []
            for k in copies { all += tri.map { SIMD2($0.x + k, $0.y) } }
            return all
        }
        d.fineLand = fill(geo.patches.flatMap { $0.rings })
        d.fineWater = fill(geo.patches.flatMap { $0.water })
        d.fineIslands = fill(geo.patches.flatMap { $0.islands })
        d.fineBorders = lines(geo.patches.flatMap { $0.lines }, closed: false)
        d.patches = geo.patches.map { $0.box }
        for g in gridSteps {
            var ls: [[SIMD2<Float>]] = []
            for lat in stride(from: -90 + g, to: 90, by: g) {
                ls.append(stride(from: -180.0, through: 180, by: 2).map { SIMD2(Float($0), Float(lat)) })
            }
            for lon in stride(from: -180.0, to: 180, by: g) {
                ls.append(stride(from: -84.0, through: 84, by: 2).map { SIMD2(Float(lon), Float($0)) })
            }
            d.grids[g] = lines(ls, closed: false)
        }
        return d
    }

    /// 三角形按最长边对半切，直到每条边都 ≤ maxEdge（度）。
    private static func subdivide(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, maxEdge: Float, into out: inout [SIMD2<Float>], depth: Int = 0) {
        let ab = simd_distance(a, b), bc = simd_distance(b, c), ca = simd_distance(c, a)
        let m = max(ab, bc, ca)
        if m <= maxEdge || depth > 12 { out += [a, b, c]; return }
        if m == ab { let p = (a + b) / 2; subdivide(a, p, c, maxEdge: maxEdge, into: &out, depth: depth + 1); subdivide(p, b, c, maxEdge: maxEdge, into: &out, depth: depth + 1) }
        else if m == bc { let p = (b + c) / 2; subdivide(a, b, p, maxEdge: maxEdge, into: &out, depth: depth + 1); subdivide(a, p, c, maxEdge: maxEdge, into: &out, depth: depth + 1) }
        else { let p = (c + a) / 2; subdivide(a, b, p, maxEdge: maxEdge, into: &out, depth: depth + 1); subdivide(p, b, c, maxEdge: maxEdge, into: &out, depth: depth + 1) }
    }

    private static func segment(_ a: SIMD2<Float>, _ b: SIMD2<Float>, maxLen: Float, into out: inout [SIMD2<Float>]) {
        let n = max(1, Int(ceil(simd_distance(a, b) / maxLen)))
        for s in 0..<n {
            out.append(a + (b - a) * Float(s) / Float(n))
            out.append(a + (b - a) * Float(s + 1) / Float(n))
        }
    }
}
