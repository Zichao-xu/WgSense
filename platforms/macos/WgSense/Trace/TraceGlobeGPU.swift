import AppKit
import SwiftUI
import simd

// 地图的辅助数据：星点贴图、陆地遮罩（轮廓光判断海陆用）、轮廓光顶点，以及叠在地球上的球面明暗（SwiftUI）。
// 地图本身由 Metal 渲染，见 TraceMetalMap.swift。

enum TraceGlobeTexture {

    /// 星点贴图：可平铺的一格（1024 像素对应 512 点，Retina 下不糊），透明底，固定种子生成。
    static let stars: CGImage? = {
        let size = 1024
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var seed: UInt64 = 0x2545F4914F6CDD1D
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        for _ in 0..<110 {
            let b = pow(next(), 3)
            let r = CGFloat(0.7 + b * 1.8)
            let x = CGFloat(next()) * CGFloat(size), y = CGFloat(next()) * CGFloat(size)
            ctx.setFillColor(CGColor(gray: 1, alpha: CGFloat(0.12 + b * 0.55)))
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        return ctx.makeImage()
    }()

    /// 陆地遮罩：画一张小图再降采样（720 × 360，每格 0.5°），1 = 陆地。轮廓光按它判断边缘是海还是陆。
    static let landMask: [UInt8] = {
        let w = maskWidth, h = maskHeight
        var px = [UInt8](repeating: 0, count: w * h)
        guard let img = render(width: w * 2, height: h * 2), let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return px }
        ctx.interpolationQuality = .low
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        // 海面灰 0.085、陆地灰 0.2（见 render），阈值取中间
        return px.map { $0 > 36 ? 1 : 0 }
    }()
    static let maskWidth = 720
    static let maskHeight = 360

    /// 某个方向（地心单位向量，z 指北极）落在陆地上吗。
    static func land(_ v: SIMD3<Float>) -> Float {
        let lat = asin(max(-1, min(1, v.z))), lon = atan2(v.y, v.x)
        let x = Int((lon + .pi) / (2 * .pi) * Float(maskWidth)) % maskWidth
        let y = min(maskHeight - 1, max(0, Int((.pi / 2 - lat) / .pi * Float(maskHeight))))
        // 位图内存第 0 行是图像顶部（北）（已实测验证），行号直接用
        return landMask[y * maskWidth + max(0, x)] == 1 ? 1 : 0
    }

    private static func render(width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        // 经度 -180…180 → x，纬度 90…-90 → y（CG 原点在左下，翻成上北）
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)
        func pt(_ lon: Float, _ lat: Float, _ shift: CGFloat) -> CGPoint {
            CGPoint(x: (CGFloat(lon) + 180) / 360 * w + shift, y: (90 - CGFloat(lat)) / 180 * h)
        }
        // 海面
        ctx.setFillColor(CGColor(gray: 0.085, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // 经纬网（30°）
        ctx.setStrokeColor(CGColor(gray: 0.15, alpha: 1))
        ctx.setLineWidth(1)
        for lon in stride(from: -180.0, through: 180, by: 30) {
            let x = CGFloat(lon + 180) / 360 * w
            ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: h))
        }
        for lat in stride(from: -60.0, through: 60, by: 30) {
            let y = CGFloat(90 - lat) / 180 * h
            ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: w, y: y))
        }
        ctx.strokePath()
        // 陆地与国界：环的经度已展开（可能超出 ±180），在 -w / 0 / +w 三处各画一次，跨日界线的部分折回画面
        let land = CGMutablePath()
        for c in TraceGeoData.shared.countries {
            for ring in c.fine {
                for shift in [-w, 0, w] {
                    for (i, ll) in ring.lonLat.enumerated() {
                        let p = pt(ll.x, ll.y, shift)
                        if i == 0 { land.move(to: p) } else { land.addLine(to: p) }
                    }
                    land.closeSubpath()
                }
            }
        }
        ctx.addPath(land)
        ctx.setFillColor(CGColor(gray: 0.2, alpha: 1))
        ctx.fillPath(using: .evenOdd)
        ctx.addPath(land)
        ctx.setStrokeColor(CGColor(gray: 0.36, alpha: 1))
        ctx.setLineWidth(1.4)
        ctx.strokePath()
        return ctx.makeImage()
    }

    /// 轮廓光的海陆系数：沿地球轮廓等分 120 个方向，每个方向轮廓往里一小圈是陆地的程度（0 = 海、1 = 陆），
    /// 再沿轮廓高斯平滑（前后各 8 个、约 ±24°），海陆之间慢慢过渡。光环的形状与衰减在着色器里算（见 TraceMetalMap）。
    static let rimCount = 120

    static func rimLand(cam: TraceCam) -> [Float] {
        let count = rimCount
        let center = cam.center
        let l = Float(cam.lon * .pi / 180)
        let east = SIMD3<Float>(-sin(l), cos(l), 0), north = simd_cross(center, east)
        // 每个方向：轮廓往里 0°–6° 的几处取样取平均（陆地压在边缘上 / 刚离开边缘都算）
        var raw = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let th = Float(i) / Float(count) * 2 * .pi
            let v = east * cos(th) + north * sin(th)
            var sum: Float = 0
            for a in [Float(0.01), 0.04, 0.07, 0.1] { sum += land(simd_normalize(v * cos(a) + center * sin(a))) }
            raw[i] = sum / 4
        }
        let spread = 8
        let kernel = (-spread...spread).map { exp(-Float($0 * $0) / Float(2 * 4 * 4)) }
        let kernelSum = kernel.reduce(0, +)
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            var acc: Float = 0
            for (j, w) in kernel.enumerated() { acc += raw[(i + j - spread + count) % count] * w }
            out[i] = acc / kernelSum
        }
        return out
    }
}

/// 球面明暗与边缘提亮：叠在球上，只随尺寸与缩放重画。
struct TraceGlobeShading: View, Equatable {
    var zoom: Double
    var shift: CGSize = .zero
    var pan: CGSize = .zero

    var body: some View {
        Canvas { ctx, size in
            let r = zoom * TraceGlobeProjection.side(size, shift) / 2
            let o = CGPoint(x: size.width / 2 + shift.width + pan.width, y: size.height / 2 + shift.height + pan.height)
            let disk = Path(ellipseIn: CGRect(x: o.x - r, y: o.y - r, width: r * 2, height: r * 2))
            ctx.fill(disk, with: .radialGradient(Gradient(stops: [
                .init(color: .white.opacity(0.06), location: 0),
                .init(color: .clear, location: 0.45),
                .init(color: .black.opacity(0.35), location: 1)]),
                center: CGPoint(x: o.x - r * 0.35, y: o.y - r * 0.4), startRadius: 0, endRadius: r * 1.55))
        }
    }
}

