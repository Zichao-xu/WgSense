import AppKit
import SwiftUI

// 表面分两类，职责不混：
//
//   背景板（窗口整体、侧栏、内容区）—— 玻璃，透出桌面
//   实体（磁贴、卡片、浮层）        —— 实色，浮在玻璃上
//
// 这是 Liquid Glass 的用法：玻璃是容器，内容是实的。把玻璃糊在磁贴和卡片上，
// 既看不出玻璃（小面积没有可折射的背景），又让内容失去轮廓。

// MARK: - 背景板

/// 背景板的玻璃档位。
///
/// 对应 `NSGlassEffectView.Style` 的两种：regular 更实、层次更稳；clear 更透，
/// 桌面几乎直接透过来。两档都保留，因为合不合适取决于当下的壁纸。
enum WgGlassStyle: String, CaseIterable, Identifiable {
    case regular
    case clear

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .regular: return "标准玻璃"
        case .clear: return "通透玻璃"
        }
    }

    var nsStyle: NSGlassEffectView.Style {
        switch self {
        case .regular: return .regular
        case .clear: return .clear
        }
    }
}

/// 大面积背景板的 Liquid Glass。
///
/// 这是 macOS 26 起的真玻璃（`NSGlassEffectView`）：有实时折射和镜面边缘，
/// 不是 `NSVisualEffectView` 那种只做模糊的 vibrancy。配合透明窗口，它折射的
/// 就是窗口背后的桌面 —— 这一点是实测验证过的，不是推断。
///
/// `.glassEffect()`（SwiftUI 侧的同一套东西）留给浮动小元素：工具栏按钮、
/// 胶囊、toast。
struct WgGlassBackdrop: NSViewRepresentable {
    var style: WgGlassStyle = .regular
    /// 玻璃的着色浓度。Liquid Glass 折射的是整个窗口背后的画面——不只桌面，还有
    /// 背后压着的其他窗口。壁纸对比度一高，内容就会被淹没，靠这一层把背景压下去。
    /// 这是整套外观里唯一需要手调的量。
    var tintStrength: Double = 0.55

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
        view.style = style.nsStyle
        // 铺满窗口，圆角交给窗口自己裁。
        view.cornerRadius = 0
        view.tintColor = NSColor(
            white: colorScheme == .dark ? 0 : 1,
            alpha: max(0, min(tintStrength, 0.9))
        )
    }
}

/// 把承载窗口设为透明。
///
/// 少了这一步，`.behindWindow` 背后仍然是 App 自己的不透明画布，玻璃透不出桌面。
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

/// 浮在玻璃上的实体表面。
///
/// 三级色阶全部从同一个基准推导，不再让每种表面各带一份深浅/材质参数。之前侧栏
/// 底色 0.06、内容区 0.08、中间的拖拽手柄又是 0.08×0.72，三块相邻的大色块各算各的，
/// 拼在一起必然对不齐——那些硬边就是这么来的。现在背景统一交给玻璃，实体只负责
/// 自己那一档明度。
enum WgSurface {
    /// 磁贴、卡片这类主体内容。
    static func solid(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.60)
    }

    /// 选中或悬浮时抬高一档。
    static func raised(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.80)
    }

    /// 描边，让实体在玻璃上有清晰轮廓。玻璃背景的明度随桌面壁纸变化，描边是保证
    /// 边界始终可读的那一层。
    static func border(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.08)
    }

    /// 侧栏与内容区之间的分隔——用一条 hairline 代替两块色板的明度差。
    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.07)
    }

    /// 状态色（连接绿、守护蓝等）叠在实体上的强度。
    static func tint(_ scheme: ColorScheme, selected: Bool) -> Double {
        let base = scheme == .dark ? 0.14 : 0.10
        return selected ? base * 1.8 : base
    }
}
