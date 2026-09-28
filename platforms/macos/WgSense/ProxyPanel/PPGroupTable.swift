import AppKit
import SwiftUI

// 策略组列表的 AppKit 容器：NSTableView + 每行一个 NSHostingView。
//
// 为什么不用 SwiftUI 的 List / LazyVStack（均实测过）：
//   · ScrollView + LazyVStack：每滚一帧都重新布局；变高行往回滚时还会陷入反复布局（实测卡死 51s）。
//   · List：底层虽是 NSTableView，但行复用时不区分行的种类，组头/节点行/组尾互相改建，
//     回滚到看过的区域时每帧 50–100ms 尖峰。
// 业界的结论一致（Apple 论坛 FB15241636、byla.lt “In Search of a Smooth Scroll”）：
// 大列表用 NSTableView + NSHostingView 单元格，按种类复用、行高自己给。

struct PPGroupTable: NSViewRepresentable {
    var items: [PPListItem]
    var rail: WgScrollRailModel
    var width: CGFloat
    /// 行高的快速路径：能直接算出的行（节点行）返回高度，其余返回 nil 走测量。
    var fixedHeight: (PPListItem) -> CGFloat?
    var makeRow: (PPListItem) -> AnyView

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.gridStyleMask = []
        table.usesAutomaticRowHeights = false
        table.allowsColumnReordering = false
        table.focusRingType = .none
        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.delegate = context.coordinator
        table.dataSource = context.coordinator

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false   // 由左侧刻度条代替
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 20, right: 0)
        context.coordinator.table = table
        context.coordinator.scrollObservers = WgScrollActivity.track(scroll)
        context.coordinator.scrollObservers.append(rail.link(scroll))
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.fixedHeight = fixedHeight
        c.makeRow = makeRow
        let widthChanged = abs(c.width - width) > 0.5
        c.width = width
        if c.items != items {
            c.items = items
            c.heights.removeAll()
            c.table?.reloadData()
        } else if widthChanged {
            c.heights.removeAll()
            c.table?.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<items.count))
        } else {
            // 数据未变：可见行的 SwiftUI 内容由各自的数据源订阅自行刷新，这里不做任何事。
        }
    }

    final class Coordinator: NSObject, NSTableViewDelegate, NSTableViewDataSource {
        weak var table: NSTableView?
        var scrollObservers: [Any] = []
        var items: [PPListItem] = []
        var width: CGFloat = 0
        var heights: [PPListItem.ID: CGFloat] = [:]
        var fixedHeight: (PPListItem) -> CGFloat? = { _ in nil }
        var makeRow: (PPListItem) -> AnyView = { _ in AnyView(EmptyView()) }
        /// 测量用的离屏宿主，按种类各一个。
        private var sizers: [String: NSHostingController<AnyView>] = [:]

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row < items.count else { return 1 }
            let item = items[row]
            if let h = heights[item.id] { return h }
            let h = fixedHeight(item) ?? measure(item)
            heights[item.id] = h
            return h
        }

        private func measure(_ item: PPListItem) -> CGFloat {
            let kind = item.reuseKind
            let sizer = sizers[kind] ?? NSHostingController(rootView: AnyView(EmptyView()))
            sizers[kind] = sizer
            sizer.rootView = makeRow(item)
            let size = sizer.sizeThatFits(in: CGSize(width: max(1, width), height: 100_000))
            return max(1, ceil(size.height))
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let item = items[row]
            let id = NSUserInterfaceItemIdentifier(item.reuseKind)
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? PPHostCell) ?? PPHostCell(identifier: id)
            // 复用配置期间暂停尺寸回调：替换内容本身会触发一次尺寸失效，那一次不需要重测
            // （行高已按条目缓存）；只有内容自己变化（展开穿透区等）时才重测。
            cell.onSizeChange = nil
            cell.host.rootView = makeRow(item)
            let handler: () -> Void = { [weak self, weak cell] in
                guard let self, let cell, let table = self.table else { return }
                let r = table.row(for: cell)
                guard r >= 0, r < self.items.count else { return }
                let item = self.items[r]
                guard self.fixedHeight(item) == nil else { return }
                let h = self.measure(item)
                if abs((self.heights[item.id] ?? 0) - h) > 0.5 {
                    self.heights[item.id] = h
                    NSAnimationContext.runAnimationGroup { ctx in
                        ctx.duration = 0.2
                        table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: r))
                    }
                }
            }
            if item.reuseKind != "nodes" {
                DispatchQueue.main.async { [weak cell] in cell?.onSizeChange = handler }
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let rowView = tableView.makeView(withIdentifier: .init("row"), owner: nil) as? PPPlainRowView ?? PPPlainRowView()
            rowView.identifier = .init("row")
            return rowView
        }
    }
}

extension PPListItem {
    /// 复用分组：同种行之间复用，复用时只替换数据，视图树结构不变。
    var reuseKind: String {
        switch kind {
        case .cards: return "cards"
        case .header: return "header"
        case .nodes: return "nodes"
        case .footer: return "footer"
        }
    }
}

/// 不画选中/悬停背景的行。
final class PPPlainRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
    override var isEmphasized: Bool { get { false } set {} }
}

/// 单元格：内嵌一个 SwiftUI 宿主；内容固有尺寸变化（展开穿透区等）时回调重新测高。
final class PPHostCell: NSTableCellView {
    let host = PPSizeReportingHost(rootView: AnyView(EmptyView()))
    var onSizeChange: (() -> Void)? {
        didSet { host.onInvalidate = onSizeChange }
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        host.sizingOptions = [.intrinsicContentSize]
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        host.frame = bounds
    }
}

final class PPSizeReportingHost: NSHostingView<AnyView> {
    var onInvalidate: (() -> Void)?
    private var pending = false

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        // 合并同一轮内的多次失效，下一轮主循环再测一次。
        guard !pending, onInvalidate != nil else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            self?.pending = false
            self?.onInvalidate?()
        }
    }
}
