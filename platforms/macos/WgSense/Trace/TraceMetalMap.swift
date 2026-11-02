import AppKit
import Metal
import MetalKit
import QuartzCore
import SwiftUI
import simd

// 地图的纯 Metal 渲染（替代 SceneKit）：每帧自己编码，没有场景图、没有引擎的逐帧编排开销。
//
//   一帧两趟：
//     1. 离屏（4× 多重采样）：星空 → 海面 / 经纬网 / 陆地 / 省界 / 国界（同一套网格，球面 ↔ 平面在顶点着色器里插值，见 TraceGlobeMesh）→ 光环
//     2. 上屏：侧栏底下的渐变模糊（模糊半径随横向位置连续变小）→ 国名（字模贴图上的四边形）
//   驱动：动起来时挂屏幕的 display link 按刷新率画（声明要满刷新率，不写会被系统节能压到 80–95 帧）；
//        静止时不画，只在镜头模型变化时补画一帧。全程不碰 SwiftUI。
//   坐标：顶点着色器算出「地球半径 = 1」的位置，再按地球半径（像素）和地球中心（像素）换到裁剪空间，
//        比例与 TraceGlobeProjection 一致，所以 SwiftUI 画的航线、标注照样对得上。

/// 每帧交给着色器的参数（与 Metal 里的 MapU 对齐，全是 float）。
private struct TraceMapUniforms {
    var lon: Float = 0, lat: Float = 0, morph: Float = 0, province: Float = 0
    /// 地球半径、地球中心、画幅（都是像素）。
    var radius: Float = 1, ox: Float = 0, oy: Float = 0, w: Float = 1, h: Float = 1
    /// 像素 / 点。
    var scale: Float = 2
    /// 星空贴图偏移（以贴图格为单位）。
    var starU: Float = 0, starV: Float = 0
    /// 侧栏模糊：开始减弱处、减弱到 0 处、最大半径（像素）。
    var blurStart: Float = 0, blurEnd: Float = 0, blurRadius: Float = 0
}

/// 一层的样式（与 Metal 里的 Style 对齐）。灰度是 sRGB 值，着色器里换成线性。
private struct TraceLayerStyle {
    var gray: Float
    var lift: Float
    var haze: Float
    /// 1 = 颜色在陆地灰与 gray 之间按省界系数插值（省界淡入）。
    var fade: Float
}

/// 国名四边形（与 Metal 里的 Label 对齐）：屏幕矩形与字模贴图里的位置，都是像素。
private struct TraceLabelQuad {
    var rect: SIMD4<Float>
    var uv: SIMD4<Float>
}

/// 渲染要用的全部外部状态：主线程写一份快照，渲染线程每帧取一份。
struct TraceMapState {
    var flight = TraceFlight(TraceCam.idle)
    var shift: CGSize = .zero
    var pan: CGSize = .zero
    /// 侧栏占的宽度（点）：这段底下做渐变模糊。
    var blurWidth: CGFloat = 0
    /// 画幅（点）与像素 / 点。
    var size: CGSize = .zero
    var scale: CGFloat = 2
}

final class TraceMetalRenderer: NSObject {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let mapPipeline, linePipeline, starPipeline, rimPipeline, compositePipeline, labelPipeline: MTLRenderPipelineState
    private let depthWrite, depthTestOnly, depthNone: MTLDepthStencilState
    private static let samples = 4
    static let offscreenFormat = MTLPixelFormat.rgba16Float
    static let screenFormat = MTLPixelFormat.bgra8Unorm

    private struct MapLayer {
        let buffer: MTLBuffer
        let count: Int
        let index: MTLBuffer?
        let indexCount: Int
        let primitive: MTLPrimitiveType
        let style: TraceLayerStyle
        let grid: Double?
        let province: Bool
    }
    /// 网格建好后由主线程挂上；渲染线程读（都在 lock 里）。
    private var layers: [MapLayer] = []
    private let lock = NSLock()
    private var state = TraceMapState()

    func setState(_ s: TraceMapState) {
        lock.lock(); state = s; lock.unlock()
    }

    /// 镜头此刻是否在动（飞行 / 惯性 / 自转 / 滑行）。
    var isMoving: Bool {
        lock.lock(); defer { lock.unlock() }
        return state.flight.moving
    }

    /// 光环：固定网格（每个顶点只存「第几个方向、第几圈」），形状与衰减在着色器里算；
    /// 每帧只交 120 个海陆系数，视角转过 1° 才重算。
    private let rimMesh: MTLBuffer?
    private let rimVertexCount: Int
    private var rimLand = [Float](repeating: 0, count: TraceGlobeTexture.rimCount)
    private var rimCenter: SIMD3<Float>?

    private let stars: MTLTexture?
    private let atlas: TraceLabelAtlas?

    private var msaaColor, msaaDepth, resolved: MTLTexture?
    private var targetSize = CGSize.zero

    /// 网格建好后调用（补画一帧）。
    var onReady: (() -> Void)?

    init?(device: MTLDevice) {
        self.device = device
        guard let queue = device.makeCommandQueue(),
              let lib = try? device.makeLibrary(source: Self.shaderSource, options: nil) else { return nil }
        self.queue = queue
        // 离屏用 16 位浮点（线性亮度）：光环、漫反射这类很暗的渐变在 8 位下只剩几级，会断成一圈圈台阶。
        // 上屏是 8 位：合成时自己做 sRGB 编码并加抖动，把剩下的台阶打散
        func pipeline(_ v: String, _ f: String, samples: Int, blend: (MTLBlendFactor, MTLBlendFactor)?, depth: Bool) -> MTLRenderPipelineState? {
            let color: MTLPixelFormat = samples > 1 ? Self.offscreenFormat : Self.screenFormat
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: v)
            d.fragmentFunction = lib.makeFunction(name: f)
            d.rasterSampleCount = samples
            d.colorAttachments[0].pixelFormat = color
            if let (src, dst) = blend {
                let a = d.colorAttachments[0]!
                a.isBlendingEnabled = true
                a.sourceRGBBlendFactor = src; a.sourceAlphaBlendFactor = src
                a.destinationRGBBlendFactor = dst; a.destinationAlphaBlendFactor = dst
            }
            if depth { d.depthAttachmentPixelFormat = .depth32Float }
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        let n = Self.samples
        guard let map = pipeline("mapVertex", "mapFragment", samples: n, blend: nil, depth: true),
              let line = pipeline("mapVertex", "mapFragment", samples: n, blend: nil, depth: true),
              let star = pipeline("quadVertex", "starFragment", samples: n, blend: (.one, .oneMinusSourceAlpha), depth: true),
              let rim = pipeline("rimVertex", "rimFragment", samples: n, blend: (.one, .one), depth: true),
              let comp = pipeline("quadVertex", "compositeFragment", samples: 1, blend: nil, depth: false),
              let label = pipeline("labelVertex", "labelFragment", samples: 1, blend: (.one, .oneMinusSourceAlpha), depth: false)
        else { return nil }
        mapPipeline = map; linePipeline = line; starPipeline = star; rimPipeline = rim; compositePipeline = comp; labelPipeline = label

        func depthState(_ compare: MTLCompareFunction, write: Bool) -> MTLDepthStencilState? {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)
        }
        guard let dw = depthState(.lessEqual, write: true), let dt = depthState(.lessEqual, write: false),
              let dn = depthState(.always, write: false) else { return nil }
        depthWrite = dw; depthTestOnly = dt; depthNone = dn

        let loader = MTKTextureLoader(device: device)
        stars = TraceGlobeTexture.stars.flatMap { try? loader.newTexture(cgImage: $0, options: [.SRGB: true]) }
        atlas = TraceLabelAtlas(device: device)
        var rimVerts: [Float] = []
        let rings = 9, count = TraceGlobeTexture.rimCount
        for i in 0..<count {
            for j in 0..<(rings - 1) {
                let a = Float(i), b = Float(i + 1), t0 = Float(j) / Float(rings - 1), t1 = Float(j + 1) / Float(rings - 1)
                for (k, t) in [(a, t0), (a, t1), (b, t0), (a, t1), (b, t1), (b, t0)] { rimVerts += [k, t] }
            }
        }
        rimMesh = rimVerts.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
        rimVertexCount = rimVerts.count / 2
        super.init()

        // 网格在后台建（三角剖分 + 细分，首次约数百毫秒），建好再上显存
        Task.detached(priority: .userInitiated) { [weak self] in
            let mesh = TraceGlobeMesh.shared
            await MainActor.run { self?.upload(mesh) }
        }
    }

    // MARK: 网格

    @MainActor
    private func upload(_ m: TraceGlobeMesh.Mesh) {
        func buffer(_ pts: [SIMD2<Float>]) -> MTLBuffer? {
            pts.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: max(8, $0.count), options: .storageModeShared) }
        }
        var out: [MapLayer] = []
        func add(_ pts: [SIMD2<Float>], index: [UInt32]? = nil, _ prim: MTLPrimitiveType, _ style: TraceLayerStyle, grid: Double? = nil, province: Bool = false) {
            guard !pts.isEmpty, let b = buffer(pts) else { return }
            let ib = index.flatMap { idx in idx.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) } }
            out.append(MapLayer(buffer: b, count: pts.count, index: ib, indexCount: index?.count ?? 0, primitive: prim, style: style, grid: grid, province: province))
        }
        // 颜色取不透明灰（与原贴图同色），离地高度决定先后
        add(m.ocean, index: m.oceanIdx, .triangle, TraceLayerStyle(gray: 0.085, lift: 0, haze: 0.015, fade: 0))
        for (step, pts) in m.grids { add(pts, .line, TraceLayerStyle(gray: 0.15, lift: 0.0005, haze: 0, fade: 0), grid: step) }
        add(m.land, .triangle, TraceLayerStyle(gray: 0.2, lift: 0.001, haze: 0, fade: 0))
        add(m.provinces, .line, TraceLayerStyle(gray: 0.33, lift: 0.0015, haze: 0, fade: 1), province: true)
        add(m.borders, .line, TraceLayerStyle(gray: 0.36, lift: 0.002, haze: 0, fade: 0))
        lock.lock(); layers = out; lock.unlock()
        onReady?()
    }

    // MARK: 一帧

    /// 画一帧到 display link 递来的画面缓冲（渲染线程上调用；每帧一块新缓冲，画完即提交）。
    func render(_ drawable: CAMetalDrawable) {
        TraceFPS.tick(.globe)
        lock.lock(); let st = state, layers = self.layers; lock.unlock()
        let size = st.size, scale = st.scale, shift = st.shift, pan = st.pan, blurWidth = st.blurWidth
        guard size.width > 0, size.height > 0, let cmd = queue.makeCommandBuffer() else { return }
        let px = CGSize(width: size.width * scale, height: size.height * scale)
        ensureTargets(px)
        guard let msaaColor, let msaaDepth, let resolved else { return }

        let cam = st.flight.cam(at: Date())
        let radiusPt = cam.zoom * TraceGlobeProjection.side(size, shift) / 2
        var u = TraceMapUniforms()
        u.lon = Float(cam.lon); u.lat = Float(cam.lat); u.morph = Float(cam.morph)
        u.province = Float(min(1, max(0, (cam.zoom - 3) / 3)))
        u.radius = Float(radiusPt * scale)
        u.ox = Float((size.width / 2 + shift.width + pan.width) * scale)
        u.oy = Float((size.height / 2 + shift.height + pan.height) * scale)
        u.w = Float(px.width); u.h = Float(px.height); u.scale = Float(scale)
        // 星空：地球转一整圈平移约一个画幅宽，纬度方向半圈一个画幅高（比地表慢，有景深）
        u.starU = Float(-(cam.lon / 360) * size.width / 512)
        u.starV = Float((cam.lat / 180) * size.height / 512)
        u.blurStart = Float(blurWidth * 0.2 * scale); u.blurEnd = Float(blurWidth * scale); u.blurRadius = Float(18 * scale)

        // 1. 离屏：星空 → 地图各层 → 光环
        let p1 = MTLRenderPassDescriptor()
        p1.colorAttachments[0].texture = msaaColor
        p1.colorAttachments[0].resolveTexture = resolved
        p1.colorAttachments[0].loadAction = .clear
        p1.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        p1.colorAttachments[0].storeAction = .multisampleResolve
        p1.depthAttachment.texture = msaaDepth
        p1.depthAttachment.loadAction = .clear
        p1.depthAttachment.clearDepth = 1
        p1.depthAttachment.storeAction = .dontCare
        guard let e1 = cmd.makeRenderCommandEncoder(descriptor: p1) else { return }
        if let stars {
            e1.setRenderPipelineState(starPipeline)
            e1.setDepthStencilState(depthNone)
            e1.setFragmentBytes(&u, length: MemoryLayout<TraceMapUniforms>.stride, index: 1)
            e1.setFragmentTexture(stars, index: 0)
            e1.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        let gridStep = cam.zoom < 1.6 ? 30.0 : cam.zoom < 5 ? 15 : cam.zoom < 14 ? 5 : 2
        e1.setDepthStencilState(depthWrite)
        e1.setVertexBytes(&u, length: MemoryLayout<TraceMapUniforms>.stride, index: 1)
        e1.setFragmentBytes(&u, length: MemoryLayout<TraceMapUniforms>.stride, index: 1)
        for l in layers {
            if let g = l.grid, g != gridStep { continue }
            if l.province && u.province <= 0 { continue }
            var s = l.style
            e1.setRenderPipelineState(l.primitive == .line ? linePipeline : mapPipeline)
            e1.setVertexBuffer(l.buffer, offset: 0, index: 0)
            e1.setVertexBytes(&s, length: MemoryLayout<TraceLayerStyle>.stride, index: 2)
            e1.setFragmentBytes(&s, length: MemoryLayout<TraceLayerStyle>.stride, index: 2)
            if let ib = l.index {
                e1.drawIndexedPrimitives(type: l.primitive, indexCount: l.indexCount, indexType: .uint32, indexBuffer: ib, indexBufferOffset: 0)
            } else {
                e1.drawPrimitives(type: l.primitive, vertexStart: 0, vertexCount: l.count)
            }
        }
        // 光环只属于地球形态：一开始展平就淡出
        let rimOpacity = Float(max(0, 1 - cam.morph * 4))
        if rimOpacity > 0, let rimMesh {
            if rimCenter.map({ traceAngle($0, cam.center) >= .pi / 180 }) ?? true {
                rimLand = TraceGlobeTexture.rimLand(cam: cam)
                rimCenter = cam.center
            }
            // 光环宽约 100 点（换成地球半径的倍数），不随缩放变粗
            var params = SIMD2<Float>(rimOpacity, Float(100 / max(1, radiusPt)))
            e1.setRenderPipelineState(rimPipeline)
            e1.setDepthStencilState(depthTestOnly)
            e1.setVertexBuffer(rimMesh, offset: 0, index: 0)
            e1.setVertexBytes(&params, length: 8, index: 2)
            e1.setVertexBytes(&rimLand, length: 4 * rimLand.count, index: 3)
            e1.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: rimVertexCount)
        }
        e1.endEncoding()

        // 2. 上屏：侧栏渐变模糊合成 → 国名
        let p2 = MTLRenderPassDescriptor()
        p2.colorAttachments[0].texture = drawable.texture
        p2.colorAttachments[0].loadAction = .dontCare
        p2.colorAttachments[0].storeAction = .store
        guard let e2 = cmd.makeRenderCommandEncoder(descriptor: p2) else { return }
        e2.setRenderPipelineState(compositePipeline)
        e2.setFragmentBytes(&u, length: MemoryLayout<TraceMapUniforms>.stride, index: 1)
        e2.setFragmentTexture(resolved, index: 0)
        e2.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        if let atlas {
            var quads = placeLabels(cam, size: size, scale: scale, shift: shift, pan: pan, atlas: atlas)
            if !quads.isEmpty {
                e2.setRenderPipelineState(labelPipeline)
                e2.setVertexBytes(&quads, length: MemoryLayout<TraceLabelQuad>.stride * quads.count, index: 0)
                e2.setVertexBytes(&u, length: MemoryLayout<TraceMapUniforms>.stride, index: 1)
                e2.setFragmentTexture(atlas.texture, index: 0)
                e2.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: quads.count)
            }
        }
        e2.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    private func ensureTargets(_ px: CGSize) {
        guard px != targetSize || resolved == nil else { return }
        targetSize = px
        let w = max(1, Int(px.width)), h = max(1, Int(px.height))
        func tex(_ format: MTLPixelFormat, samples: Int, usage: MTLTextureUsage) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: w, height: h, mipmapped: false)
            d.textureType = samples > 1 ? .type2DMultisample : .type2D
            d.sampleCount = samples
            d.usage = usage
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        msaaColor = tex(Self.offscreenFormat, samples: Self.samples, usage: .renderTarget)
        msaaDepth = tex(.depth32Float, samples: Self.samples, usage: .renderTarget)
        resolved = tex(Self.offscreenFormat, samples: 1, usage: [.renderTarget, .shaderRead])
    }

    // MARK: 国名

    /// 面积 × 缩放² 够大才出，大国优先，互不遮挡；地球形态下背面与贴近轮廓的不出。
    private func placeLabels(_ cam: TraceCam, size: CGSize, scale: CGFloat, shift: CGSize, pan: CGSize, atlas: TraceLabelAtlas) -> [TraceLabelQuad] {
        let proj = TraceGlobeProjection(cam: cam, size: size, shift: shift, pan: pan)
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 20, dy: 16)
        let center = cam.center
        let z2 = cam.zoom * cam.zoom
        var taken: [CGRect] = []
        var out: [TraceLabelQuad] = []
        for c in atlas.entries {
            guard taken.count < 60 else { break }
            guard c.area * z2 > 300, cam.morph > 0.5 || simd_dot(c.label, center) > 0.17 else { continue }
            let (pt, visible) = proj.project(lon: c.lon, lat: c.lat)
            guard visible, bounds.contains(pt) else { continue }
            let rect = CGRect(x: pt.x - c.size.width / 2, y: pt.y - c.size.height / 2, width: c.size.width, height: c.size.height)
            guard !taken.contains(where: { $0.intersects(rect.insetBy(dx: -6, dy: -3)) }) else { continue }
            taken.append(rect.insetBy(dx: -6, dy: -3))
            // 像素对齐，字不糊
            let x = (rect.minX * scale).rounded(), y = (rect.minY * scale).rounded()
            out.append(TraceLabelQuad(rect: SIMD4(Float(x), Float(y), Float(c.size.width * scale), Float(c.size.height * scale)), uv: c.uv))
        }
        return out
    }

    // MARK: 着色器（运行时编译，不依赖编译期 Metal 工具链）

    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct MapU { float lon, lat, morph, province, radius, ox, oy, w, h, scale, starU, starV, blurStart, blurEnd, blurRadius; };
    struct Style { float gray, lift, haze, fade; };
    struct MOut { float4 position [[position]]; float dl; float facing; };
    struct QOut { float4 position [[position]]; float2 uv; };

    // 「地球半径 = 1」的位置 → 裁剪空间：x 右、y 上、z 朝镜头（越大越近）
    static float4 toClip(float3 p, constant MapU& u) {
        float sx = u.ox + p.x * u.radius, sy = u.oy - p.y * u.radius;
        return float4(sx / u.w * 2.0 - 1.0, 1.0 - sy / u.h * 2.0, 0.5 - p.z * 0.25, 1.0);
    }

    static float srgbToLinear(float g) { return g <= 0.04045 ? g / 12.92 : pow((g + 0.055) / 1.055, 2.4); }

    vertex MOut mapVertex(uint vid [[vertex_id]], const device float2* ll [[buffer(0)]],
                          constant MapU& u [[buffer(1)]], constant Style& st [[buffer(2)]]) {
        const float d2r = 0.017453292519943295;
        float lon = ll[vid].x, lat = ll[vid].y;
        float cl = u.lon * d2r, cp = u.lat * d2r;
        float3 p = float3(cos(lat * d2r) * cos(lon * d2r), cos(lat * d2r) * sin(lon * d2r), sin(lat * d2r));
        float3 fwd = float3(cos(cp) * cos(cl), cos(cp) * sin(cl), sin(cp));
        float3 east = float3(-sin(cl), cos(cl), 0.0);
        float3 north = cross(fwd, east);
        float s = 1.0 + st.lift;
        float3 sphere = float3(dot(p, east), dot(p, north), dot(p, fwd)) * s;
        float dl = lon - u.lon;
        float3 flat = float3(dl * d2r * cos(cp), (lat - u.lat) * d2r, s);
        MOut o;
        o.position = toClip(mix(sphere, flat, u.morph), u);
        o.dl = dl;
        o.facing = dot(p, fwd);
        return o;
    }

    fragment float4 mapFragment(MOut in [[stage_in]], constant MapU& u [[buffer(1)]], constant Style& st [[buffer(2)]]) {
        // 三份副本只留离视野中心经度 ±180° 以内的那份
        if (abs(in.dl) > 180.0) discard_fragment();
        float g = st.fade > 0.5 ? mix(0.2, st.gray, u.province) : st.gray;
        float l = srgbToLinear(g);
        // 海面：球面边缘往里一层很淡的漫反射（线性亮度上叠加，与原 SceneKit 版一致），展平后消失
        l += st.haze * pow(1.0 - saturate(in.facing), 3.0) * (1.0 - u.morph);
        return float4(l, l, l, 1.0);
    }

    // 全屏三角形
    vertex QOut quadVertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        QOut o;
        o.position = float4(p * 2.0 - 1.0, 1.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    fragment float4 starFragment(QOut in [[stage_in]], constant MapU& u [[buffer(1)]], texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(filter::linear, mip_filter::none, address::repeat);
        // 贴图一格对应 512 点，按屏幕点数平铺（缩放时星点不变大）
        float2 pt = in.uv * float2(u.w, u.h) / u.scale;
        return tex.sample(s, pt / 512.0 + float2(u.starU, u.starV));
    }

    // 光环：贴着轮廓外侧的一圈；径向从轮廓起按指数衰减、尾部平滑收尾（约 100 点外淡到 0）；
    // 亮度随该方向是海是陆变化——海洋亮、陆地取海洋的 70%（差距大了像一侧被太阳照亮）
    struct ROut { float4 position [[position]]; float c; };
    vertex ROut rimVertex(uint vid [[vertex_id]], const device float2* v [[buffer(0)]], constant MapU& u [[buffer(1)]],
                          constant float2& params [[buffer(2)]], constant float* land [[buffer(3)]]) {
        float k = v[vid].x, t = v[vid].y;
        float th = k / 120.0 * 6.283185307179586;
        float r = t == 0.0 ? 0.995 : 1.0 + params.y * t;
        float falloff = exp(-1.8 * t) * (1.0 - t * t * (3.0 - 2.0 * t));
        float intensity = 0.096 * (1.0 - 0.3 * land[int(k) % 120]);
        ROut o;
        // 轮廓上的方向：东 = 屏幕右、北 = 屏幕上（与 rimLand 的取样方向一致）
        o.position = toClip(float3(cos(th) * r, sin(th) * r, 0.0), u);
        o.c = intensity * falloff * params.x;
        return o;
    }
    // 光环亮度按 sRGB 值调的（和原 SceneKit 顶点色一致），叠加前换成线性
    fragment float4 rimFragment(ROut in [[stage_in]]) { float l = srgbToLinear(in.c); return float4(l); }

    // 侧栏底下的渐变模糊：模糊半径随横向位置按 smootherstep 减小，到终点为 0；金角螺旋 32 点、按距离衰减加权
    fragment float4 compositeFragment(QOut in [[stage_in]], constant MapU& u [[buffer(1)]], texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float2 size = float2(u.w, u.h);
        float x = in.uv.x * size.x;
        float t = saturate((x - u.blurStart) / max(1.0, u.blurEnd - u.blurStart));
        float e = t * t * t * (t * (t * 6.0 - 15.0) + 10.0);
        float r = u.blurEnd > 0.0 ? u.blurRadius * (1.0 - e) : 0.0;
        float4 c = tex.sample(s, in.uv);
        if (r >= 0.5) {
            float4 acc = c; float wsum = 1.0;
            for (int i = 1; i < 32; i++) {
                float fi = float(i);
                float a = fi * 2.39996323;
                float2 o = float2(cos(a), sin(a)) * (r * sqrt(fi / 32.0)) / size;
                float w = exp(-2.0 * fi / 32.0);
                acc += tex.sample(s, in.uv + o) * w;
                wsum += w;
            }
            c = acc / wsum;
        }
        // 线性 → sRGB（屏幕是 8 位、不自动编码），再加 ±半级的三角分布抖动：暗部渐变不再断成台阶
        float3 enc = select(1.055 * pow(max(c.rgb, 0.0), float3(1.0 / 2.4)) - 0.055, c.rgb * 12.92, c.rgb <= 0.0031308);
        float2 px = in.position.xy;
        float n1 = fract(sin(dot(px, float2(12.9898, 78.233))) * 43758.5453);
        float n2 = fract(sin(dot(px, float2(39.3468, 11.135))) * 24634.6345);
        float d = (n1 + n2 - 1.0) / 255.0;
        // 光环是叠加发光：颜色允许大于透明度（预乘下就是「往背后加亮」），不能按透明度截断，否则光环被削没
        float alpha = saturate(c.a + d);
        enc = max(enc + d, 0.0);
        return float4(enc, alpha);
    }

    struct Label { float4 rect; float4 uv; };
    struct LOut { float4 position [[position]]; float2 uv; };
    vertex LOut labelVertex(uint vid [[vertex_id]], uint iid [[instance_id]], const device Label* ls [[buffer(0)]], constant MapU& u [[buffer(1)]]) {
        float2 corner = float2((vid == 1 || vid == 2 || vid == 4) ? 1.0 : 0.0, (vid == 2 || vid == 4 || vid == 5) ? 1.0 : 0.0);
        Label l = ls[iid];
        float2 p = l.rect.xy + corner * l.rect.zw;
        LOut o;
        o.position = float4(p.x / u.w * 2.0 - 1.0, 1.0 - p.y / u.h * 2.0, 0.0, 1.0);
        o.uv = mix(l.uv.xy, l.uv.zw, corner);
        return o;
    }
    fragment float4 labelFragment(LOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(coord::pixel, filter::linear);
        float a = tex.sample(s, in.uv).r * 0.5;   // 白字 50% 透明，预乘
        return float4(a, a, a, a);
    }
    """
}

/// 国名字模：所有国名一次性画进一张灰度贴图（按屏幕 2 倍），每帧只摆四边形。
final class TraceLabelAtlas {
    struct Entry {
        let area: Double
        let label: SIMD3<Float>
        let lon: Double
        let lat: Double
        /// 字的大小（点）。
        let size: CGSize
        /// 贴图里的位置（像素）：u0, v0, u1, v1。
        let uv: SIMD4<Float>
    }
    let texture: MTLTexture
    /// 按面积从大到小。
    let entries: [Entry]

    init?(device: MTLDevice) {
        let scale: CGFloat = 2
        let font = NSFont.systemFont(ofSize: WgType.caption, weight: .medium)
        let countries = TraceGeoData.shared.countriesByArea
        let width = 2048
        // 先排版：一行行往下放
        var placed: [(CTLine, CGRect, CGSize)] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for c in countries {
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: c.name, attributes: [.font: font, .foregroundColor: NSColor.white]))
            let b = CTLineGetTypographicBounds(line, nil, nil, nil)
            let size = CGSize(width: ceil(CGFloat(b) + 2), height: ceil(font.ascender - font.descender + 2))
            let w = size.width * scale, h = size.height * scale
            if x + w > CGFloat(width) { x = 0; y += rowH + 2; rowH = 0 }
            placed.append((line, CGRect(x: x, y: y, width: w, height: h), size))
            x += w + 2; rowH = max(rowH, h)
        }
        let height = Int(ceil(y + rowH))
        guard height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.setShouldSmoothFonts(false)
        // CG 原点在左下：字的基线放在格子里（翻成上为 0 的坐标）
        for (line, r, _) in placed {
            ctx.saveGState()
            ctx.translateBy(x: r.minX, y: CGFloat(height) - r.maxY)
            ctx.scaleBy(x: scale, y: scale)
            ctx.textPosition = CGPoint(x: 1, y: -font.descender + 1)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
        guard let data = ctx.data else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height, mipmapped: false)
        d.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        // 位图内存第 0 行是图像顶部
        tex.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: data, bytesPerRow: width)
        texture = tex
        entries = zip(countries, placed).map { c, p in
            Entry(area: Double(c.area), label: c.label, lon: Double(c.labelLonLat.x), lat: Double(c.labelLonLat.y), size: p.2,
                  uv: SIMD4(Float(p.1.minX), Float(p.1.minY), Float(p.1.maxX), Float(p.1.maxY)))
        }
    }
}

/// SwiftUI 包装：主线程只交状态快照，画由渲染线程按屏幕刷新做。
struct TraceMetalMapView: NSViewRepresentable {
    var flight: TraceFlight
    /// 主窗口真可见：收起就停。
    var visible: Bool
    var shift: CGSize = .zero
    var pan: CGSize = .zero
    /// 侧栏占的宽度（点）：这段底下做渐变模糊。
    var blurWidth: CGFloat = 0

    func makeNSView(context: Context) -> TraceMetalNSView { TraceMetalNSView() }

    func updateNSView(_ view: TraceMetalNSView, context: Context) {
        view.isHidden = !visible
        view.update(flight: flight, shift: shift, pan: pan, blurWidth: blurWidth, visible: visible)
    }
}

/// 地图画布：CAMetalLayer + 独立渲染线程。
///   渲染线程上挂 CAMetalDisplayLink：按屏幕刷新回调，并直接递来一块可用的画面缓冲——等缓冲、编码、提交都不在主线程。
///   动起来（飞行 / 惯性 / 自转 / 滑行）每帧画；镜头模型变了（拖动、缩放）记一笔、下一次刷新时画（同一周期的多次变化合成一帧）；
///   静止半秒后暂停 display link，一帧都不画。明确要满刷新率（不写会被系统节能压到 80–95 帧）。
final class TraceMetalNSView: NSView, CAMetalDisplayLinkDelegate {
    let renderer: TraceMetalRenderer?
    private let metalLayer = CAMetalLayer()
    private let thread = TraceRenderThread()
    private var link: CAMetalDisplayLink?
    private var mapState = TraceMapState()

    // 主线程与渲染线程共用的几个标记
    private let flags = NSLock()
    private var visible = false
    private var pending = false
    /// 渲染线程用：最近一次画的时刻。
    private var lastActive = CACurrentMediaTime()

    init() {
        let device = MTLCreateSystemDefaultDevice()
        renderer = device.flatMap { TraceMetalRenderer(device: $0) }
        super.init(frame: .zero)
        metalLayer.device = device
        metalLayer.pixelFormat = TraceMetalRenderer.screenFormat
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.maximumDrawableCount = 3
        wantsLayer = true
        renderer?.onReady = { [weak self] in self?.requestDraw() }
        thread.start()
        thread.perform { [weak self] in
            guard let self else { return }
            let l = CAMetalDisplayLink(metalLayer: self.metalLayer)
            l.delegate = self
            l.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
            l.preferredFrameLatency = 1
            l.isPaused = true
            l.add(to: .current, forMode: .default)
            self.link = l
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        let l = link
        thread.perform { l?.invalidate() }
        thread.cancel()
    }

    override func makeBackingLayer() -> CALayer { metalLayer }

    /// 只负责显示：鼠标事件交给上面的 SwiftUI 手势。
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        mapState.size = bounds.size
        mapState.scale = scale
        renderer?.setState(mapState)
        requestDraw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    func update(flight: TraceFlight, shift: CGSize, pan: CGSize, blurWidth: CGFloat, visible: Bool) {
        mapState.flight = flight
        mapState.shift = shift
        mapState.pan = pan
        mapState.blurWidth = blurWidth
        renderer?.setState(mapState)
        flags.lock(); self.visible = visible; flags.unlock()
        // 镜头模型变了：下一次刷新时画
        requestDraw()
    }

    func requestDraw() {
        guard !isHidden, bounds.width > 0 else { return }
        flags.lock(); pending = true; flags.unlock()
        thread.perform { [weak self] in
            guard let self else { return }
            self.lastActive = CACurrentMediaTime()
            self.link?.isPaused = false
        }
    }

    // 渲染线程
    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        // 要不要画按镜头模型的实时状态判断：自转缓停结束、惯性停住时这里自己知道，不用等主线程通知
        flags.lock()
        let draw = visible && (pending || (renderer?.isMoving ?? false))
        pending = false
        flags.unlock()
        if draw {
            lastActive = CACurrentMediaTime()
            renderer?.render(update.drawable)
        } else if CACurrentMediaTime() - lastActive > 0.5 {
            // 半秒没动静：暂停，静止时一帧都不画（递来的这块缓冲不提交，直接还回去）
            link.isPaused = true
        }
    }
}

/// 渲染线程：自带 RunLoop，CAMetalDisplayLink 挂在上面；其他线程往里投递任务。
final class TraceRenderThread: Thread {
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    override init() {
        super.init()
        name = "WgSense.TraceRender"
        qualityOfService = .userInteractive
    }

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        RunLoop.current.add(NSMachPort(), forMode: .default)
        ready.signal()
        while !isCancelled {
            RunLoop.current.run(mode: .default, before: .distantFuture)
        }
    }

    /// 投递到渲染线程执行（线程刚启动时先等它就绪）。
    func perform(_ block: @escaping () -> Void) {
        if runLoop == nil { ready.wait(); ready.signal() }
        guard let rl = runLoop else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(rl)
    }
}
