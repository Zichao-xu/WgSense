import AppKit
import SwiftUI

@main
struct RegionColorRegression {
    @MainActor static func main() throws {
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); checks += 1
        }
        for invalid in ["", "xyzxyz", "#ABCDEF", "12345", "1234567", "１２３４５６"] {
            check(WgRegionColor(invalid).color == nil, "Invalid preference must preserve default: \(invalid)")
        }
        check(Set(WgSurfaceRegion.allCases.map(\.key)).count == 3, "Region preference keys must be independent")
        for raw in ["000000", "FFFFFF", "17354D", "DED5BA", "28C840", "ABCDEF"] {
            let config = WgRegionColor(raw)
            check(config.color != nil, "Valid color missing")
            check(WgRegionColor.encode(config.color!) == raw, "Color must round trip")
            let raised = WgRegionColor.encode(config.fill(default: .clear, raised: true))
            check(raised != raw, "Hover/selection must remain distinct")
        }
        check(WgRegionColor("000000").scheme == .dark, "Dark background requires light text")
        check(WgRegionColor("FFFFFF").scheme == .light, "Light background requires dark text")
        check(WgRegionColor("28C840").scheme == .light, "Green background requires dark text")
        let suite = "local.wgsense.region-regression.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("vibrancy", forKey: "backdropMode")
        defaults.set(0.70, forKey: "glassTintStrength")
        for region in WgSurfaceRegion.allCases {
            defaults.set("17354D", forKey: region.key)
            check(UserDefaults(suiteName: suite)!.string(forKey: region.key) == "17354D", "Persistence")
            defaults.set("", forKey: region.key)
            check(defaults.string(forKey: region.key) == "", "Reset")
        }
        check(defaults.string(forKey: "backdropMode") == "vibrancy", "Region settings must not alter backdrop")
        check(defaults.double(forKey: "glassTintStrength") == 0.70, "Region settings must not alter backdrop density")

        // Render the real native panel, including light/dark text and hover fill.
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        var fixtures = 0
        for scheme in [ColorScheme.dark, .light] {
            for raw in ["", "17354D", "DED5BA", "28C840"] {
                for raised in [false, true] {
                    let config = WgRegionColor(raw)
                    let root = VStack(alignment: .leading, spacing: 10) {
                        Text("区域底色 · Region color").font(.title2)
                        Text("VPN 已连接 · 495 Mbps").foregroundStyle(.secondary)
                    }
                    .padding(20).frame(width: 340, height: 140, alignment: .leading)
                    .wgGlassPanel(ChamferShape(12), raised: raised)
                    .environment(\.wgRegionColor, config)
                    .environment(\.colorScheme, scheme)
                    .background(scheme == .dark ? Color(white: 0.04) : Color(white: 0.95))
                    let host = NSHostingView(rootView: root)
                    host.frame = NSRect(x: 0, y: 0, width: 340, height: 140)
                    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.contentView = host
                    host.layoutSubtreeIfNeeded()
                    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Native rendering failed") }
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(scheme)-\(raw.isEmpty ? "default" : raw)-\(raised ? "raised" : "normal").png"))
                    window.orderOut(nil)
                    fixtures += 1
                }
            }
        }
        let result: [String: Any] = ["checks": checks, "nativePanelFixtures": fixtures, "failures": 0]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("results.json"))
        print("Region colors: \(checks) checks, \(fixtures) native panel renders, 0 failures")
    }
}
