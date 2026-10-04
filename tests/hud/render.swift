import AppKit
import SwiftUI

@main
struct HUDRender {
    @MainActor static func main() throws {
        let output = CommandLine.arguments.dropFirst().first ?? "/tmp/wgsense-hud-render"
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        let base = Date(timeIntervalSince1970: 10_000)
        func populated(_ mode: String) -> WgLinkMonitor {
            let monitor = WgLinkMonitor()
            var rx: UInt64 = 0, tx: UInt64 = 0
            for i in 0...24 {
                if mode != "quiet" { rx += mode.hasSuffix("-max-rebind") ? 1_000_000_000 : UInt64(210000 + ((i * 7919) % 240000) * 7) }
                if mode != "quiet" && (!mode.hasPrefix("stall") || i < 4) { tx += UInt64(20000 + ((i * 3571) % 15000) * 2) }
                let rebinds = mode.hasSuffix("-max-rebind") && i == 24 ? 12
                    : (mode == "unstable" && i == 24 ? 4 : ((mode == "stall-rebind" && i >= 5) || (mode == "rebind" && i == 24) ? 2 : 0))
                monitor.ingest(handshake: mode == "handshake" && i == 24 ? "hs-2" : "hs-1", handshakeAge: mode == "handshake" && i == 24 ? 0 : 8 + i * 2, tx: tx, rx: rx,
                               rebinds: rebinds,
                               tunnelUp: true, at: base.addingTimeInterval(Double(i * 2)))
            }
            return monitor
        }
        var fixtureCount = 0, reelCount = 0
        func render(_ name: String, phase: WgLinkPhase, monitor: WgLinkMonitor, width: CGFloat,
                    scheme: ColorScheme, now: Date, entrance: Date? = nil, reduce: Bool = false,
                    pointer: CGPoint? = nil, selection: WgHUDFocus? = nil, interaction: Date? = nil,
                    caption: String? = nil) throws {
            let stage = WgLinkStage(phase: phase, monitor: monitor, frozenAt: now, frozenEntrance: entrance,
                                    frozenReduceMotion: reduce, frozenPointer: pointer,
                                    frozenSelection: selection, frozenInteraction: interaction)
                .frame(width: width)
                .environment(\.colorScheme, scheme)
            let view = VStack(spacing: 0) {
                if let caption {
                    HStack {
                        Text(caption).font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("离线演示 · 合成数据").font(.system(size: 10))
                    }
                    .foregroundStyle(Color(white: scheme == .dark ? 0.65 : 0.35))
                    .padding(.horizontal, 20).frame(height: 40)
                }
                stage
            }.frame(width: width)
                .background(scheme == .dark ? Color(red: 0.055, green: 0.061, blue: 0.07)
                                           : Color(red: 0.95, green: 0.955, blue: 0.96))
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let image = renderer.cgImage else { fatalError("render failed: \(name)") }
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("PNG failed") }
            try data.write(to: URL(fileURLWithPath: output).appendingPathComponent(name + ".png"))
            if name.hasPrefix("reel/") { reelCount += 1 } else { fixtureCount += 1 }
        }
        let good = populated("normal"), stall = populated("stall"), unstable = populated("unstable")
        let handshake = populated("handshake"), rebound = populated("rebind")
        let recovered = populated("stall")
        recovered.ingest(handshake: "hs-2", handshakeAge: 0, tx: 5_000_000, rx: 50_000_000,
                         rebinds: 0, tunnelUp: true, at: base.addingTimeInterval(50))
        // Terminal fixtures must outlast the full 1.25 s continuous response.
        let settled = base.addingTimeInterval(50)
        let themes: [(String, ColorScheme)] = [("dark", .dark), ("light", .light)]
        let widths: [CGFloat] = [373, 493, 776]
        for (name, phase) in [("linked", WgLinkPhase.linked), ("home", .home), ("idle", .idle), ("offline", .offline), ("connecting", .connecting)] {
            for (theme, scheme) in themes {
                for width in widths {
                    try render("\(name)-\(theme)-\(Int(width))", phase: phase, monitor: good, width: width, scheme: scheme, now: settled)
                }
            }
        }
        for (name, monitor) in [("stall", stall), ("unstable", unstable), ("missing", WgLinkMonitor()), ("stall-rebind", populated("stall-rebind")), ("quiet", populated("quiet"))] {
            for (theme, scheme) in themes {
                for width in widths {
                    try render("\(name)-\(theme)-\(Int(width))", phase: .linked, monitor: monitor, width: width, scheme: scheme, now: settled)
                }
            }
        }
        let alarmTime = stall.snapshot.alarmEvent!
        let sampleTimes: [Double] = [0, 1.0 / 120, 1.0 / 60, 0.04, 0.08, 0.14, 0.22,
                                     0.35, 0.50, 0.70, 0.95, 1.25, 1.35, 1.60]
        let sequences: [(String, WgLinkMonitor, Date, Date?)] = [
            ("entry", good, settled, settled),
            ("alarm-stall", stall, alarmTime, nil),
            ("alarm-unstable", unstable, unstable.snapshot.alarmEvent!, nil),
            ("handshake", handshake, handshake.snapshot.handshakeEvent!, nil),
            ("rebind", rebound, rebound.snapshot.rebindEvent!, nil),
            ("recovery", recovered, recovered.snapshot.recoveryEvent!, nil)
        ]
        for (name, monitor, event, entrance) in sequences {
            for (index, elapsed) in sampleTimes.enumerated() {
                try render("\(name)-motion-\(String(format: "%02d", index))-\(String(format: "%04d", Int((elapsed * 1000).rounded())))ms",
                           phase: .linked, monitor: monitor, width: 776, scheme: .dark,
                           now: event.addingTimeInterval(elapsed), entrance: entrance)
            }
        }

        // Inspect the entire responsive family: both selected lanes, pointer
        // parallax, and historical inspection at either end of the trace.
        for (theme, scheme) in themes {
            for width in widths {
                for selection in [WgHUDFocus.receive, .send] {
                    try render("focus-\(selection.rawValue)-\(theme)-\(Int(width))", phase: .linked,
                               monitor: good, width: width, scheme: scheme, now: settled,
                               selection: selection, interaction: settled.addingTimeInterval(-1.6))
                }
                let historyY: CGFloat = width < 600 ? 385 : 289
                let pointers: [(String, CGPoint)] = [
                    ("body", CGPoint(x: width * 0.36, y: 136)),
                    ("history-oldest", CGPoint(x: 90, y: historyY)),
                    ("history-newest", CGPoint(x: width - 23, y: historyY))
                ]
                for (name, pointer) in pointers {
                    try render("hover-\(name)-\(theme)-\(Int(width))", phase: .linked, monitor: good,
                               width: width, scheme: scheme, now: settled, pointer: pointer)
                }
                for (name, monitor) in [("linked", good), ("stall", stall), ("unstable", unstable)] {
                    let event = monitor.snapshot.alarmEvent ?? settled
                    try render("reduce-\(name)-\(theme)-\(Int(width))", phase: .linked,
                               monitor: monitor, width: width, scheme: scheme, now: event,
                               entrance: event, reduce: true, pointer: CGPoint(x: width - 25, y: historyY),
                               selection: .send, interaction: event)
                }
            }
            try render("narrow-summary-\(theme)", phase: .linked, monitor: good, width: 220,
                       scheme: scheme, now: settled)
        }
        let focusTimes: [Double] = [0, 1.0 / 120, 0.06, 0.15, 0.30, 0.55, 0.85, 1.6]
        for selection in [WgHUDFocus.receive, .send] {
            for (index, elapsed) in focusTimes.enumerated() {
                try render("focus-\(selection.rawValue)-motion-\(String(format: "%02d", index))",
                           phase: .linked, monitor: good, width: 776, scheme: .dark,
                           now: settled.addingTimeInterval(elapsed),
                           pointer: CGPoint(x: selection == .receive ? 180 : 365, y: 150),
                           selection: selection, interaction: settled)
            }
        }
        // The fullest receive blade and all twelve self-heal marks must stay
        // separate even in the smallest full composition and both alarm colors.
        for mode in ["stall-max-rebind", "unstable-max-rebind"] {
            let monitor = populated(mode)
            precondition(monitor.snapshot.rxLevel == 8 && monitor.snapshot.rebindsLastHour >= 12,
                         "maximum/gutter fixture must actually exercise the crowded geometry")
            precondition(monitor.snapshot.alarm == (mode.hasPrefix("stall") ? .transmitStall : .unstable),
                         "maximum/gutter fixture must exercise its named alarm")
            for (theme, scheme) in themes {
                for reduce in [false, true] {
                    try render("\(mode)-\(theme)-373-\(reduce ? "reduced" : "settled")", phase: .linked,
                               monitor: monitor, width: 373, scheme: scheme, now: settled,
                               reduce: reduce, pointer: CGPoint(x: 347, y: 85), selection: .receive,
                               interaction: settled.addingTimeInterval(-1.6))
                }
            }
        }
        if CommandLine.arguments.contains("--reel") {
            try FileManager.default.createDirectory(atPath: output + "/reel", withIntermediateDirectories: true)
            let reelFPS = 120, reelSeconds = 10
            for f in 0..<(reelFPS * reelSeconds) {
                let time = Double(f) / Double(reelFPS)
                let monitor: WgLinkMonitor
                let stamp: Date
                let entry: Date?
                let selection: WgHUDFocus?
                let interaction: Date?
                let pointer: CGPoint?
                let caption: String
                switch time {
                case ..<1.6:
                    monitor = good; stamp = settled.addingTimeInterval(time); entry = settled
                    selection = nil; interaction = nil; pointer = nil
                    caption = "01 / 逐层入场 · 弹性归位"
                case ..<3.2:
                    let elapsed = time - 1.6
                    monitor = good; stamp = settled.addingTimeInterval(elapsed); entry = nil
                    selection = .receive; interaction = settled
                    pointer = CGPoint(x: 165 + 140 * WgHUDMotion.smoothstep(elapsed / 1.6),
                                      y: 120 + 25 * sin(elapsed * .pi / 1.6))
                    caption = "02 / 聚焦接收 · 指针带动构成"
                case ..<4.8:
                    let elapsed = time - 3.2
                    monitor = good; stamp = settled.addingTimeInterval(elapsed); entry = nil
                    selection = .send; interaction = settled
                    pointer = CGPoint(x: 385 - 110 * WgHUDMotion.smoothstep(elapsed / 1.6),
                                      y: 185 - 22 * sin(elapsed * .pi / 1.6))
                    caption = "03 / 聚焦发送 · 连续缓入回弹"
                case ..<6.2:
                    let elapsed = time - 4.8
                    monitor = handshake; stamp = base.addingTimeInterval(48 + elapsed); entry = nil
                    selection = nil; interaction = nil
                    pointer = CGPoint(x: 96 + 635 * WgHUDMotion.smoothstep(elapsed / 1.4), y: 289)
                    caption = "04 / 握手确认 · 沿轨迹查看采样"
                case ..<8.1:
                    let elapsed = time - 6.2
                    monitor = unstable; stamp = unstable.snapshot.alarmEvent!.addingTimeInterval(elapsed); entry = nil
                    selection = nil; interaction = nil; pointer = nil
                    caption = "05 / 频繁自愈 · 告警与留痕"
                default:
                    let elapsed = time - 8.1
                    monitor = recovered; stamp = base.addingTimeInterval(50 + elapsed); entry = nil
                    selection = nil; interaction = nil; pointer = nil
                    caption = "06 / 遥测恢复 · 构成重新舒展"
                }
                try autoreleasepool {
                    try render("reel/\(String(format: "%04d", f))", phase: .linked, monitor: monitor, width: 776,
                               scheme: .dark, now: stamp, entrance: entry, pointer: pointer,
                               selection: selection, interaction: interaction, caption: caption)
                }
            }
        }
        print("Rendered \(fixtureCount) native HUD fixtures to \(output)")
        if reelCount > 0 { print("Rendered \(reelCount) synthetic reel frames at 120 fps (10 s); this is not a live performance measurement") }
    }
}
