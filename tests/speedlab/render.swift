import AppKit
import SwiftUI

// 测速台 HUD 离线逐帧渲染：只编译 HUD 与数据模型，不启动 WgSense、不连守护进程、不弹窗口。
// 夹具 = 2026-10-24 op 宽带直连实测（4 Hz），按真实节奏回放一次完整测速。
//
// 用法：render <输出目录> [帧号...]   帧号按 24fps，从按下 START 起算；不给则输出一组关键帧。

@main
struct SpeedLabRender {
    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    static let tick = 0.25
    static let dl: [Double] = [46, 345, 496, 512, 493, 505, 486, 485, 519, 488, 454, 543, 494, 476, 536, 483, 510, 491, 491, 513,
                               484, 431, 454, 498, 502, 507, 499, 495, 510, 503, 497, 501, 506, 498, 492, 504, 500, 503, 499, 502]
    static let ul: [Double] = [210, 560, 952, 968, 961, 968, 969, 971, 963, 966, 970, 972, 964, 969, 973, 968, 962, 970, 971, 967,
                               965, 972, 969, 970, 966, 971, 968, 973, 969, 970, 964, 971, 972, 968, 970, 971, 969, 970, 972, 971]
    static let rtt: [Double] = [5.3, 5.1, 5.4, 5.2, 5.0, 5.3, 5.2, 5.6, 5.1, 5.2, 5.4, 5.2]

    // 时间表（秒，自按下 START）
    static let tInfo = 0.4, tIdle = 0.9, tPick = 4.0, tSrc = [6.8, 7.3, 7.0], tDL = 7.6, tUL = 18.4, tDone = 29.2
    static let tReconn = tDL + 0.3 + 14 * tick

    static func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }

    /// 截至 now 已经发生的全部事件。
    static func data(now: Date) -> SLHUDData {
        var d = SLHUDData()
        let t = now.timeIntervalSince(t0)
        d.runner = "OpenClash"; d.path = "direct"; d.target = "公网"; d.isPublic = true
        d.downThreads = 12; d.upThreads = 4; d.tick = tick
        guard t >= 0 else { return d }
        d.startedAt = t0
        d.running = t < tDone
        d.phaseDates[.prepare] = t0
        func info(_ k: String, _ v: String, _ s: Double) { if t >= s { d.info[k] = v; d.infoDates[k] = at(s) } }
        info("iface", "pppoe-wan", tInfo); info("phy", "wan", tInfo); info("link", "1000 full", tInfo); info("mtu", "1492", tInfo)
        info("exit", "当前 IP：203.88.40.177  来自于：中国 广东 深圳  topway.com.cn", tInfo + 0.5)
        if t >= tInfo { d.link = 1000 }
        if t >= tIdle { d.phaseDates[.idle] = at(tIdle) }
        for (i, v) in rtt.enumerated() where t >= tIdle + Double(i + 1) * tick {
            d.idle.append(SLTimedSample(v: v, rtt: v, at: at(tIdle + Double(i + 1) * tick)))
        }
        if t >= tPick { d.phaseDates[.pick] = at(tPick) }
        let srcs = [("dl", "https://issuepcdn.baidupcs.com/x.exe", 427.0, true),
                    ("dl", "https://dldir1.qq.com/x.exe", 74.0, false),
                    ("ul", "https://test.ustc.edu.cn/backend/empty.php", 473.0, true)]
        for (i, s) in srcs.enumerated() where t >= tSrc[i] {
            d.sources.append(SLSourceResult(dir: s.0, url: s.1, mbps: s.2, keep: s.3, at: at(tSrc[i])))
        }
        info("src_ip", "180.76.76.76", tSrc[0] + 0.1)
        if t >= tDL { d.phaseDates[.dl] = at(tDL) }
        for (i, v) in dl.enumerated() where t >= tDL + 0.3 + Double(i) * tick {
            d.down.append(SLTimedSample(v: v, rtt: 5.7 + Double((i * 7) % 5) * 0.08, at: at(tDL + 0.3 + Double(i) * tick)))
        }
        if t >= tReconn { d.reconnects.append(SLConnEvent(dir: "dl", n: 6, at: at(tReconn))) }
        if t >= tUL { d.phaseDates[.ul] = at(tUL) }
        for (i, v) in ul.enumerated() where t >= tUL + 0.3 + Double(i) * tick {
            d.up.append(SLTimedSample(v: v, rtt: 5.6 + Double((i * 3) % 4) * 0.08, at: at(tUL + 0.3 + Double(i) * tick)))
        }
        if t >= tDone { d.finishedAt = at(tDone); d.phaseDates[.done] = at(tDone); d.running = false }
        return d
    }

    @MainActor static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let out = args.first ?? "/tmp/speedlab-render"
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let frames = args.count > 1 ? args.dropFirst().compactMap(Int.init)
            : [-12, 4, 24, 60, 100, 168, 172, 182, 184, 186, 260, 452, 456, 470, 700, 701, 702, 703, 704, 760]
        for f in frames {
            let now = at(Double(f) / 24 + 1e-4)
            let width = CGFloat(Double(ProcessInfo.processInfo.environment["WIDTH"] ?? "") ?? 1280)
            let view = SLHUD(data: data(now: now), now: now)
                .frame(width: width, height: width * 720 / 1280)
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: view)
            renderer.scale = CGFloat(Double(ProcessInfo.processInfo.environment["SCALE"] ?? "") ?? 1)
            guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            try png.write(to: URL(fileURLWithPath: "\(out)/f\(String(format: "%04d", f + 100)).png"))
        }
        print("rendered \(frames.count) frames → \(out)")
    }
}
