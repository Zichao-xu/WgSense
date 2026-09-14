import AppKit
import SwiftUI

// 表面分两层，职责不混：
//
//   背景板（整窗）—— 玻璃，透出桌面
//   实体（磁贴、卡片、面板）—— 实色，浮在玻璃上
//
// 可调参数按「层」组织，不按「表面 × 主题 × 明暗」做笛卡尔积——后者正是之前
// 44 个参数的来源：每加一种表面就多四个旋钮，旋钮之间互相抵消，永远调不到位。
// 现在一共 4 个量：背景浓度，以及实体的底色、描边、状态色。明暗模式由同一个
// 值内部映射，不各存一份。

// MARK: - 背景板

/// 背景板的三种模式。
enum WgBackdropMode: String, CaseIterable, Identifiable {
    /// Liquid Glass 标准档：折射明显，层次稳。
    case liquidRegular
    /// Liquid Glass 通透档：桌面几乎直接透过来。
    case liquidClear
    /// 传统毛玻璃（vibrancy）：只做模糊，没有折射和镜面边缘，但更安静。
    case vibrancy

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .liquidRegular: return "标准玻璃"
        case .liquidClear: return "通透玻璃"
        case .vibrancy: return "毛玻璃"
        }
    }

    var nsGlassStyle: NSGlassEffectView.Style {
        self == .liquidClear ? .clear : .regular
    }
}

/// 整窗背景板。按模式切换两种实现。
struct WgBackdrop: View {
    var mode: WgBackdropMode
    /// 玻璃之上的着色浓度。
    ///
    /// 这一层是必需的，不是多余的旋钮：Liquid Glass 折射的是整个窗口背后的画面，
    /// 不只桌面，还有压在后面的其他窗口。壁纸对比度一高，内容就会被淹没。
    var tintStrength: Double

    var body: some View {
        switch mode {
        case .vibrancy:
            WgVibrancyBackdrop(tintStrength: tintStrength)
        case .liquidRegular, .liquidClear:
            WgLiquidGlassBackdrop(style: mode.nsGlassStyle, tintStrength: tintStrength)
        }
    }
}

/// macOS 26 起的真 Liquid Glass：有实时折射与镜面边缘。
///
/// 配合透明窗口，它折射的就是窗口背后的桌面——这点是实测验证过的，不是推断。
/// SwiftUI 侧的同一套东西（`.glassEffect()`）留给浮动小元素：工具栏按钮、胶囊、toast。
private struct WgLiquidGlassBackdrop: NSViewRepresentable {
    var style: NSGlassEffectView.Style
    var tintStrength: Double

    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        // 背景板本身不承载内容，内容由 SwiftUI 叠在它上面。
        view.contentView = NSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        apply(to: view)
    }

    private func apply(to view: NSGlassEffectView) {
        view.style = style
        // 铺满窗口，圆角交给窗口自己裁。
        view.cornerRadius = 0
        view.tintColor = NSColor(
            white: colorScheme == .dark ? 0 : 1,
            alpha: max(0, min(tintStrength, 0.9))
        )
    }
}

/// 传统 vibrancy 毛玻璃。
///
/// `.behindWindow` 混合才能透出桌面；SwiftUI 的 `.ultraThinMaterial` 默认是
/// `.withinWindow`，只模糊窗口内部已经画好的内容，窗口透明时背后什么都没有。
private struct WgVibrancyBackdrop: View {
    var tintStrength: Double
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VibrancyView()
            // NSVisualEffectView 没有 tintColor，浓度用叠加层实现，与玻璃档位共用同一个滑块。
            .overlay {
                Rectangle()
                    .fill(colorScheme == .dark ? Color.black : Color.white)
                    .opacity(max(0, min(tintStrength, 0.9)))
            }
    }

    private struct VibrancyView: NSViewRepresentable {
        func makeNSView(context: Context) -> NSVisualEffectView {
            let view = NSVisualEffectView()
            apply(to: view)
            return view
        }

        func updateNSView(_ view: NSVisualEffectView, context: Context) {
            apply(to: view)
        }

        private func apply(to view: NSVisualEffectView) {
            view.material = .sidebar
            view.blendingMode = .behindWindow
            view.state = .active
        }
    }
}

/// 把承载窗口设为透明。
///
/// 少了这一步，背景板背后仍然是 App 自己的不透明画布，玻璃透不出桌面。
struct WgTransparentWindow: NSViewRepresentable {
    /// 在视图挂到窗口的那一刻就设置，比在 makeNSView 里异步取 window 可靠 ——
    /// 那时窗口往往还没 attach，设置会落空，玻璃也就透不出来。
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            Self.makeTransparent(window)
        }

        static func makeTransparent(_ window: NSWindow?) {
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
        }
    }

    func makeNSView(context: Context) -> NSView {
        Probe()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Probe.makeTransparent(nsView.window)
    }
}

// MARK: - 实体色阶

/// 实体层的三个可调量。
///
/// 存的是深色模式下的值，浅色模式由同一个值内部映射——不各存一份，参数就不会翻倍。
struct WgSurfaceTuning: Equatable {
    /// 磁贴、卡片的底色浓度。
    var fill: Double
    /// 描边强度。玻璃背景的明度随桌面变化，描边是保证边界始终可读的那一层。
    var border: Double
    /// 状态色（连接绿、守护蓝）叠在实体上的强度。
    var tint: Double

    static let standard = WgSurfaceTuning(fill: 0.07, border: 0.10, tint: 0.14)

}

/// 浮在玻璃上的实体表面。三级明度全部从 `tuning.fill` 推导，不再各表面独立取值。
enum WgSurface {
    /// 磁贴、卡片这类主体内容。
    static func solid(_ scheme: ColorScheme, _ tuning: WgSurfaceTuning) -> Color {
        scheme == .dark
            ? Color.white.opacity(tuning.fill)
            : Color.white.opacity(min(1, 0.45 + tuning.fill * 2.2))
    }

    /// 选中或悬浮时抬高一档。
    static func raised(_ scheme: ColorScheme, _ tuning: WgSurfaceTuning) -> Color {
        scheme == .dark
            ? Color.white.opacity(min(1, tuning.fill * 1.7))
            : Color.white.opacity(min(1, 0.45 + tuning.fill * 3.4))
    }

    /// 实体轮廓。
    static func border(_ scheme: ColorScheme, _ tuning: WgSurfaceTuning) -> Color {
        scheme == .dark
            ? Color.white.opacity(tuning.border)
            : Color.black.opacity(tuning.border * 0.8)
    }

    /// 侧栏与内容区之间的分隔——用一条 hairline 代替两块色板的明度差。
    static func hairline(_ scheme: ColorScheme, _ tuning: WgSurfaceTuning) -> Color {
        scheme == .dark
            ? Color.white.opacity(tuning.border * 0.7)
            : Color.black.opacity(tuning.border * 0.6)
    }

    /// 状态色叠加强度。
    static func tint(_ tuning: WgSurfaceTuning, selected: Bool) -> Double {
        selected ? min(1, tuning.tint * 1.8) : tuning.tint
    }
}
