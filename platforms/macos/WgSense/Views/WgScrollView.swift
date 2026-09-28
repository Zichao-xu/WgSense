import AppKit
import Combine
import SwiftUI

// 原生滚动容器：NSScrollView + 整页一个 SwiftUI 宿主。
//
// SwiftUI 的 ScrollView 在 macOS 上每滚一帧都让内容重新布局（采样可见 NSHostingView.layout 占满主线程）。
// 这里滚动完全交给 AppKit：内容宿主尺寸固定，滚动只是移动剪裁区，SwiftUI 不参与。
// 不做懒加载——适合普通页面；长列表用 PPGroupTable 那种按行复用的表格。
//
// 内容是独立的宿主根：外层环境（EnvironmentObject、locale、tint）不会自动传进来，
// 调用方在 content 里自行注入。

struct WgScrollView: NSViewRepresentable {
    var content: AnyView
    var contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = contentInsets
        let document = WgFlippedView()
        scroll.documentView = document
        let host = context.coordinator.controller
        host.view.translatesAutoresizingMaskIntoConstraints = true
        document.addSubview(host.view)
        context.coordinator.attach(scroll: scroll, document: document)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        // 纵向按理想高度排版（等同 ScrollView 内的语义），Spacer 等弹性视图不会被撑到无限高。
        context.coordinator.controller.rootView = AnyView(content.fixedSize(horizontal: false, vertical: true).modifier(WgScrollHitGate()))
        context.coordinator.relayout()
    }

    final class Coordinator: NSObject {
        let controller = NSHostingController(rootView: AnyView(EmptyView()))
        private weak var scroll: NSScrollView?
        private weak var document: NSView?
        private var observers: [Any] = []
        private var pending = false

        override init() {
            super.init()
            // preferredContentSize 只用作“内容尺寸变了”的信号；真实高度按当前宽度另行测量。
            controller.sizingOptions = [.preferredContentSize]
            observers.append(controller.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
                self?.scheduleRelayout()
            })
        }

        func attach(scroll: NSScrollView, document: NSView) {
            self.scroll = scroll
            self.document = document
            scroll.contentView.postsFrameChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main
            ) { [weak self] _ in self?.relayout() })
            observers.append(contentsOf: MainActor.assumeIsolated { WgScrollActivity.track(scroll) })
        }

        private func scheduleRelayout() {
            // 滚动中不重测文档高度，停下后再补。
            if MainActor.assumeIsolated({ WgScrollActivity.isScrolling }) {
                MainActor.assumeIsolated { WgScrollActivity.whenIdle("wgscroll.\(ObjectIdentifier(self).hashValue)") { [weak self] in self?.relayout() } }
                return
            }
            guard !pending else { return }
            pending = true
            DispatchQueue.main.async { [weak self] in
                self?.pending = false
                self?.relayout()
            }
        }

        private var lastSize: CGSize = .zero

        func relayout() {
            guard let scroll, let document else { return }
            let width = scroll.contentView.bounds.width
            guard width > 1 else { return }
            let fitted = controller.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude))
            let size = CGSize(width: width, height: ceil(fitted.height))
            guard size != lastSize else { return }
            lastSize = size
            document.frame = CGRect(origin: .zero, size: size)
            controller.view.frame = document.bounds
        }
    }
}

/// 左上角为原点的文档视图（内容从顶部开始排）。
final class WgFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 滚动期间“冻结”界面上的动态刷新：数据照常接收，但写入界面的动作先按 key 暂存（只留最新一次），
/// 滚动结束再一次性提交。滚动时 SwiftUI 不必重排整页，用户也察觉不到——停下的瞬间就是最新值。
@MainActor
enum WgScrollActivity {
    private(set) static var isScrolling = false
    private static var pending: [String: () -> Void] = [:]
    private static var active = 0

    static func begin() {
        active += 1
        isScrolling = true
        if !WgScrollState.shared.isScrolling { WgScrollState.shared.isScrolling = true }
    }

    static func end() {
        active = max(0, active - 1)
        guard active == 0 else { return }
        isScrolling = false
        WgScrollState.shared.isScrolling = false
        let work = pending
        pending.removeAll()
        work.values.forEach { $0() }
    }

    /// 不在滚动时立即执行；滚动中则暂存（同 key 只保留最新）。
    static func whenIdle(_ key: String, _ block: @escaping () -> Void) {
        if isScrolling { pending[key] = block } else { block() }
    }

    /// 把某个 NSScrollView 的实时滚动接入冻结机制。
    static func track(_ scroll: NSScrollView) -> [Any] {
        let center = NotificationCenter.default
        return [
            center.addObserver(forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: .main) { _ in
                MainActor.assumeIsolated { begin() }
            },
            center.addObserver(forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: .main) { _ in
                MainActor.assumeIsolated { end() }
            },
        ]
    }
}

/// 供 SwiftUI 订阅的滚动状态（只在滚动开始/结束时各变一次）。
@MainActor
final class WgScrollState: ObservableObject {
    static let shared = WgScrollState()
    @Published var isScrolling = false
}

/// 滚动期间关闭内容的点击/悬停判定：内容在静止的鼠标下移动，会被当成鼠标持续移动，
/// 每帧触发悬停更新（拓扑高亮重算、追踪区域重建）。停下后立即恢复。
struct WgScrollHitGate: ViewModifier {
    @ObservedObject private var state = WgScrollState.shared
    func body(content: Content) -> some View {
        content.allowsHitTesting(!state.isScrolling)
    }
}
