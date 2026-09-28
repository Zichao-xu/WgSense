import AppKit
import SwiftUI

// 图纸语言（B9 定稿）：
//
//   · 只有黑、白、灰。强调色 = 白色弱玻璃（半透明白 + 背景模糊 + 顶部细高光），不再有克莱因蓝。
//   · 材质三层：窗口深色液态玻璃（背景板）→ 黑色弱玻璃面板（内容底）→ 白色弱玻璃（选中 / 章节名）。
//     全部是单一透明度的纯色，不用渐变色。
//   · 形状：斜切角（右上 + 左下）。大面板 22、磁贴 12、按钮 8；页签是平行四边形。
//   · 层级：白玻璃实心块（章节）→ 白色细框（小节、信息块）→ 无框正文与数据。
//   · 图形：放大 + 淡出的图标/Logo 水印，只负责辨识度，不抢读数。
//   · 状态色只留给异常：警示琥珀、告警朱红。

enum WgInk {
    /// 强调（历史名沿用）：深色模式为白，浅色模式为近黑。选中项的实体用 `wgGlassAccent`，这里只给线、点、文字用。
    static let signal = adaptive(light: NSColor(white: 0.08, alpha: 1), dark: NSColor(white: 1, alpha: 1))
    /// 警示（中等延迟、接近配额）。
    static let warn = adaptive(light: NSColor(srgbRed: 0.70, green: 0.45, blue: 0.08, alpha: 1),
                               dark: NSColor(srgbRed: 0.93, green: 0.68, blue: 0.28, alpha: 1))
    /// 告警（高延迟、超时、失败）。
    static let alert = adaptive(light: NSColor(srgbRed: 0.78, green: 0.20, blue: 0.16, alpha: 1),
                                dark: NSColor(srgbRed: 1.00, green: 0.42, blue: 0.36, alpha: 1))
    /// 开关、滑块等系统控件的着色：中灰（白色会与控件白色旋钮混在一起）。
    static let control = adaptive(light: NSColor(white: 0.25, alpha: 1), dark: NSColor(white: 0.62, alpha: 1))

    // MARK: 字号层级（全局唯一来源）
    //   页标题 40 · 章节标题 20 · 小节标题 15 · 正文 13 · 辅助 11 · 等宽注释 9.5–10.5；大读数 30 细体。
    static let sizePage: CGFloat = 40
    static let sizeSection: CGFloat = 20
    static let sizeSubsection: CGFloat = 15
    static let sizeBody: CGFloat = 13
    static let sizeCaption: CGFloat = 11
    static let sizeReadout: CGFloat = 30

    // MARK: 斜切尺寸
    static let cutPanel: CGFloat = 22
    static let cutTile: CGFloat = 12
    static let cutControl: CGFloat = 8

    /// 黑色弱玻璃面板的底色（单一透明度纯色，叠在背景模糊之上）。
    static func panelFill(_ scheme: ColorScheme, raised: Bool = false) -> Color {
        scheme == .dark
            ? Color(red: 0.063, green: 0.067, blue: 0.078).opacity(raised ? 0.8 : 0.72)
            : Color(white: 0.97).opacity(raised ? 0.86 : 0.78)
    }
    /// 面板内分区底：比面板亮一档，不加框。
    static let well = Color.primary.opacity(0.05)
    static func panelBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.08)
    }

    static let ink = Color.primary
    static let ink2 = Color.primary.opacity(0.66)
    static let ink3 = Color.primary.opacity(0.45)
    static let ink4 = Color.primary.opacity(0.24)
    /// 发丝线：分隔、网格。
    static let rule = Color.primary.opacity(0.09)
    /// 次级区域底（卡片内的分区）。
    static let field = Color.primary.opacity(0.04)

    // MARK: 字体

    /// 注释体：等宽小字，用于代号、坐标轴、英文注记。
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

    /// 把历史代码里的彩色 tint 归一到调色板：琥珀/黄 → 警示，红 → 告警，其余 → 白（强调）。
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

// MARK: - 斜切形状

/// 斜切矩形：可分别指定四角的切角大小（0 = 直角）。默认右上 + 左下。
struct ChamferShape: InsettableShape {
    var tl: CGFloat = 0
    var tr: CGFloat
    var br: CGFloat = 0
    var bl: CGFloat
    var inset: CGFloat = 0

    init(_ cut: CGFloat) { tr = cut; bl = cut }
    init(tl: CGFloat = 0, tr: CGFloat = 0, br: CGFloat = 0, bl: CGFloat = 0) {
        self.tl = tl; self.tr = tr; self.br = br; self.bl = bl
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        let m = min(r.width, r.height) / 2
        let a = min(tl, m), b = min(tr, m), c = min(br, m), d = min(bl, m)
        var p = Path()
        p.move(to: CGPoint(x: r.minX + a, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - b, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + b))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - c))
        p.addLine(to: CGPoint(x: r.maxX - c, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + d, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - d))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + a))
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> ChamferShape { var s = self; s.inset += amount; return s }
}

/// 平行四边形（页签）：左下、右上各斜 `slant`。
struct SlantShape: Shape {
    var slant: CGFloat = 8
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + slant, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - slant, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// MARK: - 材质

/// 在画布里画一块形状底板（填充 + 描边 + 顶部细高光）。
///
/// 为什么不直接用 `shape.fill()`：隐藏标题栏的窗口要算“哪些区域是内容、不能拖动窗口”，SwiftUI 会把每个带形状的
/// 背景都算进去，非矩形路径在滚动的每一帧都要重新栅格化（实测滚动掉帧 5% → 55%）。画布对系统而言只是一个矩形。
struct WgShapePlate<S: Shape>: View {
    var shape: S
    var fill: Color
    var border: Color
    var highlight: Color

    var body: some View {
        Canvas { ctx, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
            let path = shape.path(in: rect)
            ctx.fill(path, with: .color(fill))
            ctx.stroke(path, with: .color(border), lineWidth: 1)
            // 顶部细高光：只取形状上沿一条。
            var top = ctx
            top.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: 1.5)))
            top.stroke(path, with: .color(highlight), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// 黑色弱玻璃面板：单一透明度深色 + 发丝边 + 顶部细高光（不加模糊材质，背景板本身已是模糊玻璃）。
struct WgGlassPanel<S: Shape>: ViewModifier {
    var shape: S
    var raised = false
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.background(
            WgShapePlate(shape: shape,
                         fill: WgInk.panelFill(colorScheme, raised: raised),
                         border: WgInk.panelBorder(colorScheme),
                         highlight: Color.white.opacity(colorScheme == .dark ? 0.10 : 0.5))
        )
    }
}

/// 白色弱玻璃（强调）：半透明白 + 细亮边。用于选中项与章节名。
struct WgGlassAccent<S: Shape>: ViewModifier {
    var shape: S
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.background(
            WgShapePlate(shape: shape,
                         fill: colorScheme == .dark ? Color.white.opacity(0.17) : Color.black.opacity(0.10),
                         border: colorScheme == .dark ? Color.white.opacity(0.2) : Color.black.opacity(0.14),
                         highlight: Color.white.opacity(colorScheme == .dark ? 0.5 : 0.8))
        )
    }
}

extension View {
    func wgGlassPanel<S: Shape>(_ shape: S, raised: Bool = false) -> some View {
        modifier(WgGlassPanel(shape: shape, raised: raised))
    }
    func wgGlassAccent<S: Shape>(_ shape: S) -> some View {
        modifier(WgGlassAccent(shape: shape))
    }
    /// 历史接口：顶层卡片面板 = 大斜切黑色弱玻璃。
    func wgPanel(cornerRadius: CGFloat = 2, marks: Bool = true) -> some View {
        modifier(WgGlassPanel(shape: ChamferShape(marks ? WgInk.cutPanel : WgInk.cutTile)))
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
                Text(verbatim: parts.unit.uppercased())
                    .font(WgInk.mono(max(9, size * 0.36)))
                    .foregroundStyle(WgInk.ink3)
            }
        }
        .lineLimit(1)
    }
}

// MARK: - 强调底上的环境

private struct WgOnAccentKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// 内容正压在白色玻璃强调上（选中项）。
    var wgOnAccent: Bool {
        get { self[WgOnAccentKey.self] }
        set { self[WgOnAccentKey.self] = newValue }
    }
}

// MARK: - 旧母题（保留接口，逐步退役）

struct WgCornerMarks: Shape {
    var length: CGFloat = 7
    func path(in r: CGRect) -> Path {
        var p = Path()
        let l = min(length, r.width / 3, r.height / 3)
        p.move(to: CGPoint(x: r.minX, y: r.minY + l)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - l, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - l))
        return p
    }
}

/// 带刻痕的发丝线（章节名后的延伸线）：每 24pt 一个刻痕，每 5 个一个长刻痕。
struct WgRuler: View {
    var opacity: Double = 0.5
    var body: some View {
        Canvas { ctx, size in
            let y = size.height / 2
            var base = Path()
            base.move(to: CGPoint(x: 0, y: y))
            base.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(base, with: .color(Color.primary.opacity(opacity)), lineWidth: 1)
            var i = 0
            var x: CGFloat = 0.5
            while x < size.width {
                let major = i % 5 == 0
                var t = Path()
                t.move(to: CGPoint(x: x, y: y - (major ? 4.5 : 2.5)))
                t.addLine(to: CGPoint(x: x, y: y + (major ? 4.5 : 2.5)))
                ctx.stroke(t, with: .color(Color.primary.opacity(opacity * 1.1)), lineWidth: 1)
                x += 24; i += 1
            }
        }
        .frame(height: 10)
        .allowsHitTesting(false)
    }
}

/// 签名方块（章节名前的实心小方块）。
struct WgSignalMark: View {
    var size: CGFloat = 8
    var body: some View {
        Rectangle().fill(WgInk.signal).frame(width: size, height: size)
    }
}

// MARK: - 章节标题

/// 章节标题：白色弱玻璃斜切块（小方块 + 标题）→ 带刻痕的延伸线 → 英文注记 → 附件按钮。
/// `index` 参数保留兼容，不再显示（大号编号已按定稿去掉）。
struct WgSectionMark<Accessory: View>: View {
    var index: String = ""
    var title: LocalizedStringKey
    var caption: String = ""
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                WgSignalMark(size: 8)
                Text(title)
                    .font(.system(size: WgInk.sizeSection, weight: .heavy))
                    .tracking(0.8)
                    .foregroundStyle(WgInk.ink)
            }
            .padding(.leading, 14).padding(.trailing, 26)
            .frame(height: 38)
            .wgGlassAccent(ChamferShape(tr: 12))
            WgRuler(opacity: 0.45)
            if !caption.isEmpty {
                Text(verbatim: caption.uppercased())
                    .font(WgInk.mono(10, .medium))
                    .tracking(1.8)
                    .foregroundStyle(WgInk.ink3)
                    .fixedSize()
                    .padding(.leading, 12)
            }
            HStack(spacing: 2) { accessory() }.padding(.leading, 6)
        }
    }
}

extension WgSectionMark where Accessory == EmptyView {
    init(index: String = "", title: LocalizedStringKey, caption: String = "") {
        self.init(index: index, title: title, caption: caption, accessory: { EmptyView() })
    }
}

/// 小节标签：白色细框斜切（代号 + 标题），比章节名低一级。
struct WgTagBox: View {
    var code: String = ""
    var title: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            if !code.isEmpty {
                Text(verbatim: code).font(WgInk.mono(10, .medium)).tracking(1.2).foregroundStyle(WgInk.ink2)
            }
            Text(title).font(.system(size: WgInk.sizeSubsection, weight: .bold)).foregroundStyle(WgInk.ink)
        }
        .padding(.leading, 8).padding(.trailing, 16).padding(.vertical, 4)
        .overlay(WgShapePlate(shape: ChamferShape(tr: WgInk.cutControl), fill: .clear, border: Color.primary.opacity(0.55), highlight: .clear))
    }
}

// MARK: - 图形水印

/// 放大 + 淡出的图标水印：SF Symbol 放大到角落，低透明度，朝内淡出。只负责辨识度，不接收事件。
struct WgGhostSymbol: View {
    var symbol: String
    var size: CGFloat = 84
    var opacity: Double = 0.14

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .ultraLight))
            .foregroundStyle(Color.primary.opacity(opacity))
            .allowsHitTesting(false)
    }
}

/// 应用标志：切角盾形外框 + W 折线 + 右上角切口标注线。
struct WgLogoMark: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height) / 100
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(18, 10)); path.addLine(to: p(72, 10)); path.addLine(to: p(90, 28)); path.addLine(to: p(90, 70))
        path.addLine(to: p(62, 92)); path.addLine(to: p(28, 92)); path.addLine(to: p(10, 74)); path.addLine(to: p(10, 18)); path.closeSubpath()
        path.move(to: p(28, 30)); path.addLine(to: p(40, 70)); path.addLine(to: p(50, 44)); path.addLine(to: p(60, 70)); path.addLine(to: p(72, 30))
        path.move(to: p(72, 10)); path.addLine(to: p(72, 28)); path.addLine(to: p(90, 28))
        return path
    }
}
