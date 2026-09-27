import SwiftUI

// 设计基元：控制中心 + 系统设置的视觉语言。
//
//   圆形徽章    —— 侧栏模块（控制中心）。状态靠徽章上色，磁贴本体保持中性。
//   圆角方徽章  —— 概览里的分组列表（系统设置）。
//
// 颜色只表达状态：开启才上色，关闭一律回到中性灰，不给“未运行”的东西配彩色。

enum WgDesign {
    static let tileRadius: CGFloat = 4
    static let cardRadius: CGFloat = 4
    static let heroRadius: CGFloat = 5

    static let spring = Animation.spring(response: 0.32, dampingFraction: 0.82)
}

// MARK: - 徽章

/// 控制中心式圆形徽章：开启时实色渐变 + 白色图标，关闭时中性灰底。
struct WgCircleBadge: View {
    var symbol: String
    var tint: Color
    var isOn: Bool
    var size: CGFloat = 30
    var isBusy: Bool = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.wgOnAccent) private var onAccent
    @State private var spin = false

    var body: some View {
        // 仪表语言：方块而非圆片。开启 = 实色块 + 反白图标；关闭 = 发丝框。
        // 开启 = 实墨块（颜色只留给警示/告警与“当前选中”，否则满屏蓝块就不再有焦点）。
        let normalized = WgInk.normalize(tint)
        let color: Color = (normalized == WgInk.warn || normalized == WgInk.alert) ? normalized : WgInk.ink
        let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
        ZStack {
            if isOn {
                shape.fill(onAccent ? Color.white : color)
            } else {
                shape.fill(offFill)
                shape.strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
            }
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(isOn ? (onAccent ? WgInk.signal : Color(nsColor: .windowBackgroundColor)) : Color.primary.opacity(0.7))
                .contentTransition(.symbolEffect(.replace))
            if isBusy {
                shape
                    .trim(from: 0, to: 0.25)
                    .stroke(onAccent ? Color.white : color, style: StrokeStyle(lineWidth: 1.5))
                    .padding(-3)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear {
                        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
                    }
            }
        }
        .frame(width: size, height: size)
        .animation(WgDesign.spring, value: isOn)
    }

    private var offFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.04) : Color.black.opacity(0.03)
    }
}

/// 行首方徽章：仪表语言下不再上彩色——中性底板 + 发丝描边 + 墨色图标。
/// `tint` 保留参数兼容，只在归一后属于警示/告警时才着色图标。
struct WgSquareBadge: View {
    var symbol: String
    var tint: Color
    var size: CGFloat = 24
    var dimmed: Bool = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
        // 行首图标纯装饰：一律墨色，彩色 tint 不再上色（否则会被读成“警示”）。
        let glyph: Color = dimmed ? WgInk.ink3 : WgInk.ink2
        shape
            .fill(WgInk.field)
            .overlay(shape.strokeBorder(WgInk.rule))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.46, weight: .medium))
                    .foregroundStyle(glyph)
            }
    }
}

// MARK: - 状态点

struct WgStatusDot: View {
    var color: Color
    var isOn: Bool
    var body: some View {
        Rectangle()
            .fill(isOn ? (color == .green ? WgInk.signal : WgInk.normalize(color)) : Color.secondary.opacity(0.35))
            .frame(width: 6, height: 6)
    }
}

// MARK: - 可点击表面（磁贴 / 卡片）

/// 统一的可点击表面：中性实体底、悬停抬高、选中描边。
///
/// 本体不是 Button，而是 onTapGesture —— 这样内部的 Button 能正常接收点击。
/// 嵌套 Button 时外层会吃掉内层点击，这是之前磁贴里按钮点不动的根因。
struct WgInteractiveSurface: ViewModifier {
    var cornerRadius: CGFloat = WgDesign.tileRadius
    var isSelected: Bool = false
    var isEnabled: Bool = true
    var action: (() -> Void)?

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: min(cornerRadius, 3), style: .continuous)
        let hot = hovering && action != nil && isEnabled
        let dark = colorScheme == .dark
        content
            // 选中 = 整块克莱因蓝实底，内容按深色外观反白。这是全局唯一的“大面积颜色”，
            // 所以当前所在的位置永远一眼可辨。
            .environment(\.colorScheme, isSelected ? .dark : colorScheme)
            .environment(\.wgOnAccent, isSelected)
            .background {
                ZStack {
                    if isSelected {
                        shape.fill(WgInk.signal)
                    } else {
                        shape.fill(dark ? Color.white.opacity(hot ? 0.06 : 0.028) : Color.white.opacity(hot ? 0.8 : 0.6))
                        shape.strokeBorder(dark ? Color.white.opacity(hot ? 0.2 : 0.09) : Color.black.opacity(hot ? 0.2 : 0.1), lineWidth: 1)
                        WgCornerMarks(length: 6)
                            .stroke(Color.primary.opacity(hot ? 0.8 : (dark ? 0.45 : 0.5)), lineWidth: 1.5)
                            .padding(0.75)
                    }
                }
                .allowsHitTesting(false)
            }
            .clipShape(shape)
            .contentShape(shape)
            .onHover { hovering = $0 }
            .onTapGesture { if isEnabled { action?() } }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.18), value: isSelected)
    }
}

extension View {
    func wgInteractiveSurface(
        cornerRadius: CGFloat = WgDesign.tileRadius,
        isSelected: Bool = false,
        isEnabled: Bool = true,
        action: (() -> Void)? = nil
    ) -> some View {
        modifier(WgInteractiveSurface(cornerRadius: cornerRadius, isSelected: isSelected, isEnabled: isEnabled, action: action))
    }
}

// MARK: - 按钮样式

/// 模块里的次级操作：中性底，按下略缩；只有“激活”时图标上色。
struct WgActionButtonStyle: ButtonStyle {
    var isActive: Bool = false
    var tint: Color = WgInk.signal

    func makeBody(configuration: Configuration) -> some View {
        ActionBody(configuration: configuration, isActive: isActive, tint: tint)
    }

    private struct ActionBody: View {
        let configuration: Configuration
        let isActive: Bool
        let tint: Color
        @State private var hovering = false
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.wgOnAccent) private var onAccent

        var body: some View {
            configuration.label
                .foregroundStyle(isActive ? (onAccent ? WgInk.signal : Color.white) : Color.primary.opacity(0.78))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(fill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(isActive ? .clear : Color.primary.opacity(hovering ? 0.22 : 0.1), lineWidth: 1)
                )
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }

        private var fill: Color {
            if isActive { return onAccent ? Color.white : WgInk.normalize(tint) }
            let base = colorScheme == .dark ? Color.white : Color.black
            return base.opacity(hovering ? 0.10 : 0.055)
        }
    }
}

/// 主操作胶囊（连接 / 断开）。
struct WgCapsuleButtonStyle: ButtonStyle {
    var tint: Color
    var prominent: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        CapsuleBody(configuration: configuration, tint: tint, prominent: prominent)
    }

    private struct CapsuleBody: View {
        let configuration: Configuration
        let tint: Color
        let prominent: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(prominent ? Color.white : tint)
                .padding(.horizontal, 18)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill(prominent ? AnyShapeStyle(WgInk.normalize(tint)) : AnyShapeStyle(WgInk.normalize(tint).opacity(colorScheme == .dark ? 0.18 : 0.12)))
                )
                .brightness(hovering && isEnabled ? 0.04 : 0)
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// 头部的无边框图标按钮：平时透明，悬停出现圆形底。
struct WgToolbarIconButtonStyle: ButtonStyle {
    var isActive: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        IconBody(configuration: configuration, isActive: isActive)
    }

    private struct IconBody: View {
        let configuration: Configuration
        let isActive: Bool
        @State private var hovering = false
        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isActive ? WgInk.signal : Color.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .strokeBorder(Color.primary.opacity(hovering || isActive ? 0.25 : 0), lineWidth: 1)
                )
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .contentShape(Rectangle())
                .focusEffectDisabled()
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

// MARK: - 文本格式

enum WgFormat {
    static func speed(_ bytesPerSec: Double) -> String {
        let bps = max(0, bytesPerSec)
        if bps < 1024 { return String(format: "%.0f B/s", bps) }
        if bps < 1024 * 1024 { return String(format: "%.1f KB/s", bps / 1024) }
        if bps < 1024 * 1024 * 1024 { return String(format: "%.1f MB/s", bps / (1024 * 1024)) }
        return String(format: "%.1f GB/s", bps / (1024 * 1024 * 1024))
    }

    static func size(_ bytes: UInt64) -> String {
        let b = Double(bytes)
        if b < 1024 { return String(format: "%.0f B", b) }
        if b < 1024 * 1024 { return String(format: "%.1f KB", b / 1024) }
        if b < 1024 * 1024 * 1024 { return String(format: "%.1f MB", b / (1024 * 1024)) }
        return String(format: "%.2f GB", b / (1024 * 1024 * 1024))
    }

    static func age(_ seconds: Int) -> String {
        if seconds < 5 { return "刚刚" }
        if seconds < 60 { return "\(seconds) 秒前" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        return "\(seconds / 3600) 小时前"
    }
}

// MARK: - 页面框架

/// 所有页面共用：同一种标题排版、同一内容宽度、同一纵向节奏。
struct WgPage<Accessory: View, Content: View>: View {
    var title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    var maxWidth: CGFloat = 820
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            WgPageHeader(title: title, subtitle: subtitle, accessory: accessory)
            content()
        }
        .frame(maxWidth: maxWidth, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

extension WgPage where Accessory == EmptyView {
    init(title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, maxWidth: CGFloat = 820,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, maxWidth: maxWidth, accessory: { EmptyView() }, content: content)
    }
}

/// 页面标题：签名方块 + 大标题 + 副标题，下方刻度尺线。所有页面（含代理页）共用。
struct WgPageHeader<Accessory: View>: View {
    var title: LocalizedStringKey
    var subtitle: LocalizedStringKey? = nil
    var subtitleText: String? = nil
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .lastTextBaseline, spacing: 12) {
                WgSignalMark(size: 10).alignmentGuide(.lastTextBaseline) { $0[.bottom] + 4 }
                Text(title)
                    .font(.system(size: 30, weight: .semibold))
                    .tracking(0.5)
                Group {
                    if let subtitle { Text(subtitle) } else if let subtitleText { Text(verbatim: subtitleText) }
                }
                .font(WgInk.mono(11))
                .foregroundStyle(WgInk.ink3)
                .lineLimit(1)
                Spacer(minLength: 12)
                accessory()
            }
            WgRuler()
        }
    }
}

// MARK: - 分组

/// 系统设置式分组：小标题 + 一块圆角实体 + 可选脚注。
struct WgSection<Content: View>: View {
    var title: LocalizedStringKey?
    var footer: LocalizedStringKey? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                HStack(spacing: 6) {
                    Rectangle().fill(WgInk.ink).frame(width: 5, height: 5)
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(WgInk.ink2)
                }
                .padding(.leading, 2)
            }
            VStack(spacing: 0) {
                content()
            }
            .wgInteractiveSurface(cornerRadius: WgDesign.cardRadius)
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }
        }
    }
}

/// 分组内的一行：方形徽章 + 标题/副标题 + 右侧控件。
struct WgRow<Accessory: View>: View {
    var symbol: String?
    var tint: Color = .gray
    var title: LocalizedStringKey
    var subtitle: Text? = nil
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 12) {
            if let symbol {
                WgSquareBadge(symbol: symbol, tint: tint, size: 24)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13))
                if let subtitle {
                    subtitle
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            accessory()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 46)
    }
}

extension WgRow where Accessory == EmptyView {
    init(symbol: String?, tint: Color = .gray, title: LocalizedStringKey, subtitle: Text? = nil) {
        self.init(symbol: symbol, tint: tint, title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// 行内右侧的只读值。
struct WgValue: View {
    var text: String
    var monospaced = false
    init(_ text: String, monospaced: Bool = false) {
        self.text = text
        self.monospaced = monospaced
    }
    var body: some View {
        Text(verbatim: text)
            .font(monospaced ? .system(size: 12, design: .monospaced) : .system(size: 13))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }
}

/// 行间分隔：从徽章之后开始，与系统设置一致。
struct WgRowDivider: View {
    var inset: CGFloat = 50
    var body: some View {
        Divider().opacity(0.5).padding(.leading, inset)
    }
}

/// 小号次级按钮：中性底胶囊，文字可带语义色（红=卸载，橙=清理）。
struct WgPillButtonStyle: ButtonStyle {
    var tint: Color = .primary

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, tint: tint)
    }

    private struct PillBody: View {
        let configuration: Configuration
        let tint: Color
        @State private var hovering = false
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .foregroundStyle(tint == .primary ? AnyShapeStyle(Color.primary.opacity(0.85)) : AnyShapeStyle(tint))
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 2, style: .continuous).fill((colorScheme == .dark ? Color.white : Color.black).opacity(hovering ? 0.11 : 0.065))
                )
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

// MARK: - 语言

/// 仅在确有必要时注入 locale（见 WgAppLanguage.needsLocaleOverride）。
struct WgLocaleOverride: ViewModifier {
    var language: WgAppLanguage
    func body(content: Content) -> some View {
        if language.needsLocaleOverride {
            content.environment(\.locale, language.locale)
        } else {
            content
        }
    }
}
