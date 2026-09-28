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
        context.coordinator.controller.rootView = content
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
        }

        private func scheduleRelayout() {
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
            let height = max(ceil(fitted.height), scroll.contentView.bounds.height - scroll.contentInsets.top - scroll.contentInsets.bottom)
            let size = CGSize(width: width, height: height)
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
