import AppKit
import Combine

/// 主窗口是否真的有人在看（被遮挡、最小化、隐藏、关闭都不算；菜单栏小面板不算）。
///
/// 图表采样、连接推送这类纯视觉数据流只在可见时运行；平时只留菜单栏图标和守护需要的低频状态轮询，
/// 出门用电池时不在后台持续解码 mihomo 推送。
@MainActor
final class WgWindowVisibility: ObservableObject {
    static let shared = WgWindowVisibility()

    @Published private(set) var isMainWindowVisible = false

    /// 切 Space、短暂遮挡不立刻拆流：持续不可见这么久才算收起。
    private static let hideDelay: TimeInterval = 3
    private var observers: [NSObjectProtocol] = []
    private var hideWork: DispatchWorkItem?

    private init() {
        let names: [Notification.Name] = [
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification,
        ]
        for name in names {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // willClose 时窗口仍在列表里，下一轮 runloop 再判断。
                DispatchQueue.main.async { self?.recompute() }
            })
        }
        isMainWindowVisible = Self.mainWindowOnScreen()
    }

    /// 普通窗口（非 NSPanel、非菜单栏条）在屏幕上可见。
    static func mainWindowOnScreen() -> Bool {
        NSApp.windows.contains {
            !($0 is NSPanel) && $0.isVisible && $0.occlusionState.contains(.visible) && $0.frame.height > 60
        }
    }

    private func recompute() {
        if Self.mainWindowOnScreen() {
            hideWork?.cancel()
            hideWork = nil
            if !isMainWindowVisible { isMainWindowVisible = true }
            return
        }
        guard isMainWindowVisible, hideWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hideWork = nil
            if !Self.mainWindowOnScreen() { self.isMainWindowVisible = false }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hideDelay, execute: work)
    }
}
