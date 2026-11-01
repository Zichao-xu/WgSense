import Foundation
import simd

// 地球底图数据（Data/TraceGeo.bin，由 tools/trace-geoprep.py 生成，来源均为 Natural Earth 公有领域数据）：
//   国家：中文名、标注点、面积、远 / 近两档轮廓；省级：每国一组边界折线。
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
            _ = r.bytes(2)
            for _ in 0..<r.u32() { provinces.append(Self.ring(r.points())) }
        }
        countriesByArea = countries.sorted { $0.area > $1.area }
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
