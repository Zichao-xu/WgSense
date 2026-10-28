import AppKit
import SwiftUI

// Keep exact geometry for the entire page. Attach native SwiftUI hosts only around
// the viewport. Fixed-height tiles need no text measurement to establish geometry;
// variable-height paragraphs still receive a real measurement at every new width.
struct VisibleNativePage: NSViewRepresentable {
    var items: [LabItem]
    var width: CGFloat
    var fontSize: CGFloat
    var readings: LiveReadings

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = false
        let document = FlippedDocument()
        scroll.documentView = document
        context.coordinator.attach(scroll, document: document)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.update(items: items, width: width, fontSize: fontSize, readings: readings)
    }

    final class FlippedDocument: NSView { override var isFlipped: Bool { true } }

    @MainActor final class Coordinator {
        weak var scroll: NSScrollView?
        weak var document: NSView?
        private var observers: [NSObjectProtocol] = []
        private var signature = ""
        private var width: CGFloat = -1
        private var items: [LabItem] = []
        private var controllers: [Int: NSHostingController<LabCell>] = [:]
        private var frames: [Int: CGRect] = [:]
        private var layingOut = false
        private var columns = 0
        private var reflowDeadline: CFTimeInterval = 0
        var geometryForVerification: [Int: CGRect] { frames }
        var mountedCount: Int { controllers.values.filter { $0.view.superview != nil }.count }
        var mountedIDs: Set<Int> { Set(controllers.filter { $0.value.view.superview != nil }.map(\.key)) }
        var controllerIdentities: [Int: ObjectIdentifier] { controllers.mapValues(ObjectIdentifier.init) }

        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

        func attach(_ scroll: NSScrollView, document: NSView) {
            self.scroll = scroll; self.document = document
            scroll.contentView.postsBoundsChangedNotifications = true
            scroll.contentView.postsFrameChangedNotifications = true
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: scroll.contentView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.mountVisible() }
                })
            }
        }

        func update(items: [LabItem], width: CGFloat, fontSize: CGFloat, readings: LiveReadings) {
            guard let scroll, let document else { return }
            let signature = "\(fontSize)|" + items.map { "\($0.id):\($0.title):\($0.note):\($0.spec):\($0.fixedHeight ?? -1)" }.joined(separator: "|")
            let changed = self.signature != signature
            if changed {
                let ids = Set(items.map(\.id))
                for id in Array(controllers.keys) where !ids.contains(id) {
                    controllers[id]?.view.removeFromSuperview(); controllers[id] = nil
                }
                for item in items {
                    let cell = LabCell(item: item, fontSize: fontSize, readings: readings)
                    if let controller = controllers[item.id] { controller.rootView = cell }
                    else {
                        let controller = NSHostingController(rootView: cell)
                        controller.sizingOptions = []
                        controllers[item.id] = controller
                    }
                }
                self.signature = signature
            }
            self.items = items
            guard changed || self.width != width else { mountVisible(); return }
            let oldOrigin = scroll.contentView.bounds.origin.y
            // Preserve the first visible item's identity and pixel offset on reflow.
            let anchor = frames.filter { $0.value.maxY > oldOrigin }.min { a, b in
                a.value.minY == b.value.minY ? a.key < b.key : a.value.minY < b.value.minY
            }
            self.width = width
            let nextColumns = GridGeometry.columns(width)
            if columns != 0 && columns != nextColumns { reflowDeadline = CACurrentMediaTime() + 0.3 }
            columns = nextColumns
            let packed = GridGeometry.pack(items.map(\.spec), columns: nextColumns)
            let indexed = GridGeometry.frames(width: width, rows: packed) { index, itemWidth in
                let item = items[index]
                return item.fixedHeight ?? controllers[item.id]!.sizeThatFits(in: CGSize(width: itemWidth, height: .greatestFiniteMagnitude)).height
            }
            frames = Dictionary(uniqueKeysWithValues: indexed.map { index, rect in
                (items[index].id, rect.offsetBy(dx: 12, dy: 12))
            })
            layingOut = true
            let height = max(scroll.contentView.bounds.height, (frames.values.map(\.maxY).max() ?? 0) + 12)
            document.frame = CGRect(x: 0, y: 0, width: width + 24, height: height)
            let anchoredY = anchor.flatMap { old in frames[old.key].map { $0.minY + oldOrigin - old.value.minY } } ?? oldOrigin
            scroll.contentView.setBoundsOrigin(CGPoint(x: 0, y: min(max(0, anchoredY), max(0, height - scroll.contentView.bounds.height))))
            scroll.reflectScrolledClipView(scroll.contentView)
            layingOut = false
            mountVisible()
        }

        func mountVisible() {
            guard !layingOut, let scroll, let document else { return }
            let visible = scroll.contentView.bounds.insetBy(dx: 0, dy: -80)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for item in items {
                guard let frame = frames[item.id], let controller = controllers[item.id] else { continue }
                if frame.intersects(visible) {
                    let wasMounted = controller.view.superview != nil
                    if !wasMounted {
                        controller.view.wantsLayer = true
                        document.addSubview(controller.view)
                    }
                    if controller.view.frame != frame {
                        let oldPosition = controller.view.layer?.presentation()?.position ?? controller.view.layer?.position
                        let changedOrigin = controller.view.frame.origin != frame.origin
                        controller.view.frame = frame
                        // Actual text reflows immediately at its new width. Animate only
                        // translation between rows; never stretch a text bitmap. The native
                        // easing is a prototype choice, not claimed identical to SwiftUI smooth.
                        let remaining = reflowDeadline - CACurrentMediaTime()
                        if wasMounted, changedOrigin, remaining > 0, let layer = controller.view.layer, let oldPosition {
                            let animation = CABasicAnimation(keyPath: "position")
                            animation.fromValue = oldPosition; animation.toValue = layer.position
                            animation.duration = remaining
                            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                            layer.add(animation, forKey: "row-reflow")
                        }
                    }
                } else if controller.view.superview != nil {
                    controller.view.removeFromSuperview()
                }
            }
            CATransaction.commit()
        }
    }
}
