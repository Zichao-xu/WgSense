import AppKit
import SwiftUI

// 仪表语言（Instrument）：工程图纸式的冷静界面。
//
//   · 灰阶承载一切信息层级：墨 / 次墨 / 淡墨 / 发丝线。
//   · 唯一强调色 = 克莱因蓝：当前选择、主数据系列、焦点。一屏里只在少数地方出现。
//   · 状态色只留给异常：警示琥珀、告警朱红。“正常”不上色——正常就该安静。
//   · 数字一律等宽；单位降一级字号、淡墨，读数先于单位入眼。
//   · 小标题用等宽注释体 + 编号，像图纸的标注，不用彩色图标块区分段落。

enum WgInk {
    /// 克莱因蓝。浅色接近 IKB（#002FA7）略提亮以保证小字可读；深色再提亮一档，否则在暗底上发闷。
    static let signal = adaptive(light: NSColor(srgbRed: 0.05, green: 0.22, blue: 0.78, alpha: 1),
                                 dark: NSColor(srgbRed: 0.36, green: 0.50, blue: 1.00, alpha: 1))
    /// 警示（中等延迟、接近配额）。
    static let warn = adaptive(light: NSColor(srgbRed: 0.70, green: 0.45, blue: 0.08, alpha: 1),
                               dark: NSColor(srgbRed: 0.93, green: 0.68, blue: 0.28, alpha: 1))
    /// 告警（高延迟、超时、失败）。
    static let alert = adaptive(light: NSColor(srgbRed: 0.78, green: 0.20, blue: 0.16, alpha: 1),
                                dark: NSColor(srgbRed: 1.00, green: 0.42, blue: 0.36, alpha: 1))

    static let ink = Color.primary
    static let ink2 = Color.primary.opacity(0.64)
    static let ink3 = Color.primary.opacity(0.42)
    static let ink4 = Color.primary.opacity(0.22)
    /// 发丝线：分隔、网格。
    static let rule = Color.primary.opacity(0.085)
    /// 次级区域底（卡片内的分区）。
    static let field = Color.primary.opacity(0.035)

    // MARK: 字体

    /// 注释体：等宽小字，用于编号、坐标轴、英文副标题。
    static func mono(_ size: CGFloat = 10, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// 读数：等宽数字。
    static func figure(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }

    /// 把 "2.0 KB/s" 拆成 ("2.0", "KB/s")，读数与单位分开排版。
    static func split(_ text: String) -> (value: String, unit: String) {
        guard let space = text.lastIndex(of: " ") else { return (text, "") }
        return (String(text[..<space]), String(text[text.index(after: space)...]))
    }

    /// 把历史代码里的彩色 tint 归一到仪表调色板：琥珀/黄 → 警示，红 → 告警，灰 → 灰，其余 → 克莱因蓝。
    static func normalize(_ tint: Color) -> Color {
        if tint == .orange || tint == .yellow { return warn }
        if tint == .red || tint == .pink { return alert }
        if tint == .gray || tint == .secondary { return .gray }
        return signal
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

// MARK: - 读数

/// 读数 + 单位：数值用正文色大字，单位淡墨小一号。
struct WgReadout: View {
    var text: String
    var size: CGFloat = 20
    var weight: Font.Weight = .regular
    var tint: Color = WgInk.ink

    var body: some View {
        let parts = WgInk.split(text)
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(verbatim: parts.value)
                .font(WgInk.figure(size, weight))
                .foregroundStyle(tint)
            if !parts.unit.isEmpty {
                Text(verbatim: parts.unit)
                    .font(WgInk.mono(max(9, size * 0.5)))
                    .foregroundStyle(WgInk.ink3)
            }
        }
        .lineLimit(1)
    }
}

// MARK: - 强调底上的环境

private struct WgOnAccentKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// 内容正压在克莱因蓝实底上：徽章、强调色元素应反白。
    var wgOnAccent: Bool {
        get { self[WgOnAccentKey.self] }
        set { self[WgOnAccentKey.self] = newValue }
    }
}

// MARK: - 定位角标

/// 四角的 L 形定位标记（图纸的裁切/注册标记）。框本身是发丝线，角标更亮——
/// 这是整套界面的签名细节：一眼看去是“被标注的区域”，而不是“圆润的卡片”。
struct WgCornerMarks: Shape {
    var length: CGFloat = 7
    func path(in r: CGRect) -> Path {
        var p = Path()
        let l = min(length, r.width / 3, r.height / 3)
        p.move(to: CGPoint(x: r.minX, y: r.minY + l)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - l, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + l))
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - l)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX - l, y: r.maxY))
        p.move(to: CGPoint(x: r.minX + l, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY - l))
        return p
    }
}

// MARK: - 刻度尺线

/// 带刻痕的发丝线：每 8pt 一个短刻痕，每 5 个一个长刻痕。放在页面标题下，像图纸的比例尺。
struct WgRuler: View {
    var body: some View {
        Canvas { ctx, size in
            var base = Path()
            base.move(to: CGPoint(x: 0, y: size.height - 0.5))
            base.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            ctx.stroke(base, with: .color(Color.primary.opacity(0.22)), lineWidth: 1)
            var i = 0
            var x: CGFloat = 0.5
            while x < size.width {
                let major = i % 5 == 0
                var t = Path()
                t.move(to: CGPoint(x: x, y: size.height))
                t.addLine(to: CGPoint(x: x, y: size.height - (major ? 6 : 3)))
                ctx.stroke(t, with: .color(Color.primary.opacity(major ? 0.35 : 0.16)), lineWidth: 1)
                x += 8; i += 1
            }
        }
        .frame(height: 7)
        .allowsHitTesting(false)
    }
}

/// 签名方块：页面标题前的一枚克莱因蓝实心方块。
struct WgSignalMark: View {
    var size: CGFloat = 9
    var body: some View {
        Rectangle().fill(WgInk.signal).frame(width: size, height: size)
    }
}

// MARK: - 段落标题

/// 图纸式段落标题：编号 · 标题 · 发丝线 · 英文注释 · 附件按钮。
struct WgSectionMark<Accessory: View>: View {
    var index: String
    var title: LocalizedStringKey
    var caption: String = ""
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 10) {
            // 反白编号块：墨底、底色字，像图纸的零件号标签。
            Text(verbatim: index)
                .font(WgInk.mono(10.5, .bold))
                .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                .padding(.horizontal, 5)
                .frame(height: 17)
                .background(Rectangle().fill(WgInk.ink))
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(WgInk.ink)
            Rectangle().fill(Color.primary.opacity(0.16)).frame(height: 1)
            if !caption.isEmpty {
                Text(verbatim: caption.uppercased())
                    .font(WgInk.mono(9.5, .medium))
                    .tracking(1.6)
                    .foregroundStyle(WgInk.signal)
                    .fixedSize()
            }
            accessory()
        }
        .frame(minHeight: 22)
    }
}

extension WgSectionMark where Accessory == EmptyView {
    init(index: String, title: LocalizedStringKey, caption: String = "") {
        self.init(index: index, title: title, caption: caption, accessory: { EmptyView() })
    }
}

// MARK: - 面板表面

/// 仪表面板：直角、近乎透明的底、发丝框 + 四角定位标记。不要高光与阴影。
struct WgPanelSurface: ViewModifier {
    var cornerRadius: CGFloat = 2
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                shape.fill(colorScheme == .dark ? Color.white.opacity(0.028) : Color.white.opacity(0.6))
                    .overlay(shape.strokeBorder(colorScheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.10), lineWidth: 1))
                    .overlay(WgCornerMarks().stroke(Color.primary.opacity(colorScheme == .dark ? 0.55 : 0.6), lineWidth: 1.5).padding(0.75))
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func wgPanel(cornerRadius: CGFloat = 2) -> some View {
        modifier(WgPanelSurface(cornerRadius: cornerRadius))
    }
}
