import AppKit
import SwiftUI

/// Each region owns a separate preference; an empty value preserves the shipped appearance.
enum WgSurfaceRegion: String, CaseIterable {
    case sidebar, toolbar, content
    var key: String { "regionColor.\(rawValue)" }
    var title: LocalizedStringKey {
        switch self {
        case .sidebar: return "左侧卡片"
        case .toolbar: return "底部工具栏"
        case .content: return "右侧内容面板"
        }
    }
}

struct WgRegionColor: Equatable {
    let raw: String
    init(_ raw: String = "") { self.raw = raw }

    /// 旧版只存 RRGGBB、丢了透明度，存下的全是不透明色，把玻璃整块盖成纯色。
    /// 旧值按默认面板的透明度读，保持「透明带颜色」。
    static let legacyOpacity = 0.72

    var rgb: (Double, Double, Double)? {
        guard raw.count == 6 || raw.count == 8, raw.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let value = UInt32(raw.prefix(6), radix: 16) else { return nil }
        return (Double((value >> 16) & 255) / 255, Double((value >> 8) & 255) / 255, Double(value & 255) / 255)
    }
    var opacity: Double {
        guard rgb != nil else { return 1 }
        guard raw.count == 8, let a = UInt32(raw.suffix(2), radix: 16) else { return Self.legacyOpacity }
        return Double(a) / 255
    }
    var color: Color? {
        guard let (r, g, b) = rgb else { return nil }
        return Color(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
    var scheme: ColorScheme? {
        guard let (r, g, b) = rgb else { return nil }
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        // Select whichever text color has the higher WCAG contrast.
        return luminance > 0.179 ? .light : .dark
    }
    func fill(default fallback: Color, raised: Bool = false) -> Color {
        guard let (r, g, b) = rgb else { return fallback }
        let amount = raised ? 0.10 : 0
        let target: Double = scheme == .dark ? 1 : 0
        return Color(.sRGB, red: r * (1 - amount) + target * amount,
                     green: g * (1 - amount) + target * amount,
                     blue: b * (1 - amount) + target * amount, opacity: opacity)
    }
    /// 存为 RRGGBBAA，保留透明度。
    static func encode(_ color: Color) -> String {
        guard let c = NSColor(color).usingColorSpace(.sRGB) else { return "" }
        func byte(_ v: CGFloat) -> Int { Int((max(0, min(v, 1)) * 255).rounded()) }
        return String(format: "%02X%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent), byte(c.alphaComponent))
    }
}

private struct WgRegionColorKey: EnvironmentKey { static let defaultValue = WgRegionColor() }
extension EnvironmentValues {
    var wgRegionColor: WgRegionColor {
        get { self[WgRegionColorKey.self] }
        set { self[WgRegionColorKey.self] = newValue }
    }
}

private struct WgSurfaceRegionModifier: ViewModifier {
    @AppStorage private var raw: String
    init(_ region: WgSurfaceRegion) { _raw = AppStorage(wrappedValue: "", region.key) }
    func body(content: Content) -> some View { content.environment(\.wgRegionColor, WgRegionColor(raw)) }
}

private struct WgRegionContrastModifier: ViewModifier {
    @Environment(\.wgRegionColor) private var region
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View { content.environment(\.colorScheme, region.scheme ?? scheme) }
}

private struct WgRegionBackgroundModifier: ViewModifier {
    @Environment(\.wgRegionColor) private var region
    func body(content: Content) -> some View {
        content.wgRegionContrast().background(region.color ?? .clear)
    }
}

extension View {
    func wgSurfaceRegion(_ region: WgSurfaceRegion) -> some View { modifier(WgSurfaceRegionModifier(region)) }
    func wgRegionContrast() -> some View { modifier(WgRegionContrastModifier()) }
    func wgRegionBackground() -> some View { modifier(WgRegionBackgroundModifier()) }
}
