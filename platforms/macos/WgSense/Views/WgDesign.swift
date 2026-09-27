import SwiftUI

// 设计基元：控制中心 + 系统设置的视觉语言。
//
//   圆形徽章    —— 侧栏模块（控制中心）。状态靠徽章上色，磁贴本体保持中性。
//   圆角方徽章  —— 概览里的分组列表（系统设置）。
//
// 颜色只表达状态：开启才上色，关闭一律回到中性灰，不给“未运行”的东西配彩色。

enum WgDesign {
    static let tileRadius: CGFloat = 14
    static let cardRadius: CGFloat = 16
    static let heroRadius: CGFloat = 20

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
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle()
                .fill(isOn ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(offFill))
            Image(systemName: symbol)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(isOn ? Color.white : Color.primary.opacity(0.62))
                .contentTransition(.symbolEffect(.replace))
            if isBusy {
                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .padding(-3)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear {
                        withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { spin = true }
                    }
            }
        }
        .frame(width: size, height: size)
        .shadow(color: isOn ? tint.opacity(colorScheme == .dark ? 0.45 : 0.28) : .clear, radius: size * 0.22, y: 1)
        .animation(WgDesign.spring, value: isOn)
    }

    private var offFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.07)
    }
}

/// 系统设置式圆角方徽章：始终上色，用于列表行首。
struct WgSquareBadge: View {
    var symbol: String
    var tint: Color
    var size: CGFloat = 24
    var dimmed: Bool = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(dimmed ? AnyShapeStyle(Color.gray.gradient) : AnyShapeStyle(tint.gradient))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

// MARK: - 状态点

struct WgStatusDot: View {
    var color: Color
    var isOn: Bool
    var body: some View {
        Circle()
            .fill(isOn ? color : Color.secondary.opacity(0.35))
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
    @AppStorage("surfaceFill") private var surfaceFill = WgSurfaceTuning.standard.fill
    @AppStorage("surfaceBorder") private var surfaceBorder = WgSurfaceTuning.standard.border
    @AppStorage("surfaceTint") private var surfaceTint = WgSurfaceTuning.standard.tint

    private var tuning: WgSurfaceTuning {
        WgSurfaceTuning(fill: surfaceFill, border: surfaceBorder, tint: surfaceTint)
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let lifted = isSelected || (hovering && action != nil && isEnabled)
        content
            .background {
                shape
                    .fill(lifted ? WgSurface.raised(colorScheme, tuning) : WgSurface.solid(colorScheme, tuning))
                    // 顶缘一道极淡高光，给实体一点厚度，不靠阴影。
                    .overlay(
                        shape.fill(
                            LinearGradient(
                                colors: [Color.white.opacity(colorScheme == .dark ? 0.05 : 0.35), .clear],
                                startPoint: .top, endPoint: .center
                            )
                        )
                    )
                    .overlay(
                        shape.strokeBorder(
                            isSelected ? Color.accentColor.opacity(0.4) : WgSurface.border(colorScheme, tuning),
                            lineWidth: 1
                        )
                    )
                    .allowsHitTesting(false)
            }
            .clipShape(shape)
            .contentShape(shape)
            .onHover { hovering = $0 }
            .onTapGesture { if isEnabled { action?() } }
            .animation(.easeOut(duration: 0.14), value: hovering)
            .animation(WgDesign.spring, value: isSelected)
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
    var tint: Color = .accentColor

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

        var body: some View {
            configuration.label
                .foregroundStyle(isActive ? tint : Color.primary.opacity(0.78))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(fill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isActive ? tint.opacity(0.35) : .clear, lineWidth: 1)
                )
                .opacity(isEnabled ? 1 : 0.4)
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }

        private var fill: Color {
            if isActive { return tint.opacity(colorScheme == .dark ? 0.18 : 0.12) }
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
                    Capsule().fill(prominent ? AnyShapeStyle(tint.gradient) : AnyShapeStyle(tint.opacity(colorScheme == .dark ? 0.18 : 0.12)))
                )
                .brightness(hovering && isEnabled ? 0.04 : 0)
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .shadow(color: prominent && isEnabled ? tint.opacity(0.30) : .clear, radius: 6, y: 2)
                .contentShape(Capsule())
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
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill((colorScheme == .dark ? Color.white : Color.black).opacity(hovering || isActive ? 0.09 : 0))
                )
                .scaleEffect(configuration.isPressed ? 0.92 : 1)
                .contentShape(Circle())
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
