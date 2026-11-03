import Foundation
import simd

// 地球底图数据（Data/TraceGeo.bin，由 tools/trace-geoprep.py 生成，来源均为 Natural Earth 公有领域数据）：
//   国家：中文名、标注点、面积、远 / 近两档轮廓；省级：每国一组边界折线。
// 重点地区的市 / 区（Data/TraceRegions.bin，由 tools/trace-regionprep.py 生成）：广东地级市与珠三角区县、东京区市町村、
//   加州与纽约州的县——名称、标注点、面积、边界环；级别 1 = 市 / 县，2 = 区县 / 区市町村，放大到不同程度才出。
//   另有几块矩形的精细陆地（广东、东京、纽约、湾区、洛杉矶）：块内用它代替底图的粗陆地，河口、海湾放大后才不成大三角。
//   读入时把每个点预先算成球面单位向量，投影时只剩一次旋转，不用每帧再算三角函数。

struct TraceGeoRing {
    /// 球面单位向量（地心坐标，z 指北极）。
    let points: [SIMD3<Float>]
    /// 经度（度，已展开、不跳 ±180）与纬度：平面形态用。
    let lonLat: [SIMD2<Float>]
    /// 外接球冠：中心方向与角半径（弧度），视野外整环跳过。
    let center: SIMD3<Float>
    let radius: Float
}

struct TraceGeoRegion {
    /// 1 = 地级市、美国县；2 = 珠三角区县、东京区市町村。
    let level: Int
    /// 所属国家（ISO 两位代码）。
    let code: String
    let name: String
    let label: SIMD3<Float>
    let labelLonLat: SIMD2<Float>
    /// 面积（平方度）：决定名字在多大的缩放下出现。
    let area: Float
    /// 边界环（只画线，不填色）。
    let rings: [[SIMD2<Float>]]
}

struct TraceGeoPatch {
    /// 矩形：西、南、东、北（度）。
    let box: SIMD4<Float>
    /// 外环（只填色）。
    let rings: [[SIMD2<Float>]]
    /// 海岸与省 / 都县 / 州界折线（块内代替底图的国界、省界）。
    let lines: [[SIMD2<Float>]]
    /// 内河水面（县界没扣的哈德逊河、东河等）与水中的岛：水面盖在陆地上，岛再盖在水面上。
    let water: [[SIMD2<Float>]]
    let islands: [[SIMD2<Float>]]
}

struct TraceGeoCountry {
    let code: String
    let name: String
    let label: SIMD3<Float>
    let labelLonLat: SIMD2<Float>
    /// 轮廓面积（平方度）：决定国名在多大的缩放下出现。
    let area: Float
    let coarse: [TraceGeoRing]
    let fine: [TraceGeoRing]
}

final class TraceGeoData {
    static let shared = TraceGeoData()

    private(set) var countries: [TraceGeoCountry] = []
    private(set) var provinces: [TraceGeoRing] = []
    /// 省级边界按国家分组（边界辐射只在跳点所在国家里传播）。
    private(set) var provincesByCountry: [String: [TraceGeoRing]] = [:]
    private(set) var regions: [TraceGeoRegion] = []
    private(set) var patches: [TraceGeoPatch] = []
    /// 国名按面积从大到小：标注时大国优先占位。初始化时就排好（底图在后台线程画，不用 lazy 免得并发初始化）。
    private(set) var countriesByArea: [TraceGeoCountry] = []

    private init() {
        guard let url = Bundle.main.url(forResource: "TraceGeo", withExtension: "bin"),
              let data = try? Data(contentsOf: url) else { return }
        var r = Reader(data)
        guard r.bytes(4) == Array("WGTG".utf8), r.u32() == 1 else { return }
        for _ in 0..<r.u32() {
            let code = String(decoding: r.bytes(2), as: UTF8.self)
            let name = String(decoding: r.bytes(Int(r.u16())), as: UTF8.self)
            let lon = r.f32(), lat = r.f32(), area = r.f32()
            let coarse = (0..<r.u32()).map { _ in Self.ring(r.points()) }
            let fine = (0..<r.u32()).map { _ in Self.ring(r.points()) }
            countries.append(TraceGeoCountry(code: code, name: name, label: Self.unit(lon, lat), labelLonLat: SIMD2(lon, lat),
                                             area: area, coarse: coarse, fine: fine))
        }
        for _ in 0..<r.u32() {
            let code = String(decoding: r.bytes(2), as: UTF8.self)
            for _ in 0..<r.u32() {
                let ring = Self.ring(r.points())
                provinces.append(ring)
                provincesByCountry[code, default: []].append(ring)
            }
        }
        countriesByArea = countries.sorted { $0.area > $1.area }
        loadRegions()
    }

    private func loadRegions() {
        guard let url = Bundle.main.url(forResource: "TraceRegions", withExtension: "bin"),
              let data = try? Data(contentsOf: url) else { return }
        var r = Reader(data)
        guard r.bytes(4) == Array("WGTR".utf8), r.u32() == 4 else { return }
        for _ in 0..<r.u32() {
            let level = Int(r.bytes(1).first ?? 0)
            let code = String(decoding: r.bytes(2), as: UTF8.self)
            let name = String(decoding: r.bytes(Int(r.u16())), as: UTF8.self)
            let lon = r.f32(), lat = r.f32(), area = r.f32()
            let rings = (0..<r.u32()).map { _ in r.points() }
            regions.append(TraceGeoRegion(level: level, code: code, name: name, label: Self.unit(lon, lat), labelLonLat: SIMD2(lon, lat),
                                          area: area, rings: rings))
        }
        for _ in 0..<r.u32() {
            _ = r.bytes(Int(r.u16()))
            let box = SIMD4(r.f32(), r.f32(), r.f32(), r.f32())
            let rings = (0..<r.u32()).map { _ in r.points() }
            let lines = (0..<r.u32()).map { _ in r.points() }
            let water = (0..<r.u32()).map { _ in r.points() }
            patches.append(TraceGeoPatch(box: box, rings: rings, lines: lines, water: water, islands: (0..<r.u32()).map { _ in r.points() }))
        }
    }

    static func unit(_ lon: Float, _ lat: Float) -> SIMD3<Float> {
        let l = lon * .pi / 180, p = lat * .pi / 180
        return SIMD3(cos(p) * cos(l), cos(p) * sin(l), sin(p))
    }

    private static func ring(_ ll: [SIMD2<Float>]) -> TraceGeoRing {
        let pts = ll.map { unit($0.x, $0.y) }
        let sum = pts.reduce(SIMD3<Float>.zero, +)
        let c = simd_length(sum) > 1e-6 ? simd_normalize(sum) : (pts.first ?? SIMD3(1, 0, 0))
        let radius = pts.map { acos(min(1, max(-1, simd_dot($0, c)))) }.max() ?? 0
        return TraceGeoRing(points: pts, lonLat: ll, center: c, radius: radius)
    }

    private struct Reader {
        let d: [UInt8]
        var i = 0
        init(_ data: Data) { d = [UInt8](data) }
        mutating func bytes(_ n: Int) -> [UInt8] {
            guard i + n <= d.count else { i = d.count; return [] }
            defer { i += n }
            return Array(d[i..<i + n])
        }
        mutating func u16() -> UInt16 { bytes(2).enumerated().reduce(0) { $0 | UInt16($1.element) << (8 * $1.offset) } }
        mutating func u32() -> UInt32 { bytes(4).enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * $1.offset) } }
        mutating func f32() -> Float { Float(bitPattern: u32()) }
        mutating func points() -> [SIMD2<Float>] {
            let n = Int(u32())
            return (0..<n).map { _ in SIMD2(f32(), f32()) }
        }
    }
}
