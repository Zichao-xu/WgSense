import SwiftUI

// 代理 · 概览（O-*）：卡片可排序/显隐；图表无极滚动；拓扑自绘桑基图。

struct PPOverviewPage: View {
    @ObservedObject private var panel = ProxyPanelStore.shared

    var body: some View {
        // 原生滚动容器（见 WgScrollView）。外层不订阅高频数据，内容自行订阅，容器不会被反复重建。
        WgScrollView(content: AnyView(
            PPOverviewContent()
                .environmentObject(panel)
                .tint(WgInk.signal)
        ))
        .onAppear {
            panel.activate()
            PPOverviewStore.shared.activate()
        }
        .onDisappear { PPOverviewStore.shared.deactivate() }
    }
}

private struct PPOverviewContent: View {
    @ObservedObject private var overview = PPOverviewStore.shared
    @State private var showCardSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 10) {
                PPStatsStrip()
                Button { showCardSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                    .buttonStyle(WgToolbarIconButtonStyle())
                    .help("卡片设置")
                    .popover(isPresented: $showCardSettings, arrowEdge: .bottom) { PPCardSettings() }
            }
            ForEach(Array(overview.cards.filter(\.visible).enumerated()), id: \.element.id) { index, setting in
                card(setting.card).environment(\.ppCardIndex, index + 1)
            }
        }
        .padding(.bottom, 24)
    }

    @ViewBuilder
    private func card(_ card: PPOverviewCard) -> some View {
        switch card {
        case .charts: PPChartsCard()
        case .network: PPNetworkCard()
        case .providerTraffic: PPProviderTrafficCard()
        case .topology: PPTopologyCard()
        case .history: PPHistoryCard()
        case .ruleHits: PPRuleHitsCard()
        }
    }
}

// MARK: - 卡片外框

private struct PPCardIndexKey: EnvironmentKey { static let defaultValue = 0 }
extension EnvironmentValues {
    /// 卡片在可见顺序中的编号（图纸式段落编号 01、02…）。
    var ppCardIndex: Int {
        get { self[PPCardIndexKey.self] }
        set { self[PPCardIndexKey.self] = newValue }
    }
}

struct PPCard<Accessory: View, Content: View>: View {
    var title: LocalizedStringKey
    var caption: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content
    @Environment(\.ppCardIndex) private var index

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            WgSectionMark(index: String(format: "%02d", index), title: title, caption: caption) {
                HStack(spacing: 2) { accessory() }
            }
            content()
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .wgPanel()
    }
}

extension PPCard where Accessory == EmptyView {
    init(title: LocalizedStringKey, caption: String, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, caption: caption, accessory: { EmptyView() }, content: content)
    }
}

// MARK: - 统计条（O-S01）

private struct PPStatsStrip: View {
    @ObservedObject private var live = PPOverviewStats.shared

    var body: some View {
        let s = live.stats
        HStack(spacing: 0) {
            metric("下载速度", "DOWN/S", WgFormat.speed(Double(s.downSpeed)))
            divider
            metric("上传速度", "UP/S", WgFormat.speed(Double(s.upSpeed)))
            divider
            metric("下载", "RX", WgFormat.size(UInt64(max(0, s.downloadTotal))))
            divider
            metric("上传", "TX", WgFormat.size(UInt64(max(0, s.uploadTotal))))
            divider
            metric("连接", "CONN", "\(s.connections)")
            divider
            metric("内存使用", "MEM", s.memory > 0 ? WgFormat.size(UInt64(s.memory)) : "—")
        }
        .padding(.vertical, 14)
        .wgPanel()
    }

    private var divider: some View {
        Rectangle().fill(Color.primary.opacity(0.14)).frame(width: 1, height: 40)
    }

    /// 读数格：上为中文名 + 等宽代号，下为读数（单位降级）。
    private func metric(_ title: LocalizedStringKey, _ code: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(verbatim: code).font(WgInk.mono(9, .semibold)).tracking(1.2).foregroundStyle(WgInk.signal)
                Text(title).font(.system(size: 11)).foregroundStyle(WgInk.ink3)
            }
            .lineLimit(1)
            // 不用 numericText 过渡：它对每个字形做模糊+位移动画，6 个数字每秒变化等于持续的 CPU 模糊卷积
            // （实测是概览页的最大开销）。等宽数字直接刷新，位置不跳。
            WgReadout(text: text, size: 24, weight: .light)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 图表卡（O-G01…O-G05）

private struct PPChartsCard: View {
    private let overview = PPOverviewStore.shared

    var body: some View {
        // 单色：主系列亮墨铺面，次系列淡墨描线；颜色不承担区分，靠明度与粗细。
        PPCard(title: "实时", caption: "Realtime · 60s") {
            VStack(spacing: 22) {
                // 下载、上传分成两条窄图，各自一个镜头：一方冲高不会把另一方压扁。
                VStack(spacing: 16) {
                    PPStreamChart(title: "下载", buffer: overview.downSpeed,
                                  series: [.init(name: "下载", color: WgInk.ink)],
                                  format: { WgFormat.speed($0) }, floor: 512)
                        .frame(height: 128)
                    PPStreamChart(title: "上传", buffer: overview.upSpeed,
                                  series: [.init(name: "上传", color: WgInk.ink2)],
                                  format: { WgFormat.speed($0) }, floor: 512)
                        .frame(height: 128)
                }
                HStack(spacing: 28) {
                    PPStreamChart(title: "内存使用", buffer: overview.memory,
                                  series: [.init(name: "内存使用", color: WgInk.ink2)],
                                  format: { WgFormat.size(UInt64(max(0, $0))) }, floor: 2 * 1024 * 1024)
                    PPStreamChart(title: "连接", buffer: overview.connectionCount,
                                  series: [.init(name: "连接", color: WgInk.ink2)],
                                  format: { String(Int($0.rounded())) }, floor: 6)
                }
                .frame(height: 150)
            }
        }
    }
}

// MARK: - 网络卡（O-N01…O-N04）

private struct PPNetworkCard: View {
    @ObservedObject private var overview = PPOverviewStore.shared
    @EnvironmentObject private var panel: ProxyPanelStore

    var body: some View {
        PPCard(title: "网络信息", caption: "Network") {
            HStack(alignment: .top, spacing: 14) {
                pane {
                    ipRow("ipip.net", overview.chinaIP)
                    ipRow(overview.ipInfoAPI.title, overview.globalIP)
                } actions: {
                    Button { overview.showPrivacy.toggle() } label: {
                        Image(systemName: overview.showPrivacy ? "eye" : "eye.slash")
                    }
                    .buttonStyle(WgToolbarIconButtonStyle())
                    .help("截图时请确保隐藏IP")
                    Button { Task { await overview.checkIP() } } label: {
                        if overview.ipChecking { ProgressView().controlSize(.small) } else { Image(systemName: "bolt.fill") }
                    }
                    .buttonStyle(WgToolbarIconButtonStyle())
                    .help("检查 IP")
                }
                pane {
                    ForEach(PPOverviewStore.latencyTargets, id: \.name) { target in
                        HStack {
                            Text(verbatim: target.name).font(.system(size: 12)).foregroundStyle(WgInk.ink2)
                            Spacer()
                            latencyText(overview.latencies[target.name])
                        }
                    }
                } actions: {
                    Button { Task { await overview.checkLatency() } } label: {
                        if overview.latencyChecking { ProgressView().controlSize(.small) } else { Image(systemName: "bolt.fill") }
                    }
                    .buttonStyle(WgToolbarIconButtonStyle())
                    .help("检查连接")
                }
            }
        }
    }

    private func pane<C: View, A: View>(@ViewBuilder _ content: () -> C, @ViewBuilder actions: () -> A) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            content()
            HStack { Spacer(); actions() }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(WgInk.field))
        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(WgInk.rule))
    }

    private func ipRow(_ source: String, _ result: PPIPResult?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: source).font(WgInk.mono(10)).foregroundStyle(WgInk.ink3).frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: result?.location ?? "—").font(.system(size: 12.5, weight: .medium)).foregroundStyle(WgInk.ink).lineLimit(1)
                if let ip = result?.ip, !ip.isEmpty {
                    Text(verbatim: overview.showPrivacy ? ip : "•••.•••.•••.•••")
                        .font(WgInk.mono(10.5)).foregroundStyle(WgInk.ink3)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func latencyText(_ ms: Int?) -> some View {
        let level = panel.level(ms ?? 0)
        return Text(verbatim: ms.map { $0 == 0 ? "超时" : "\($0) ms" } ?? "—")
            .font(WgInk.figure(12, .medium))
            .foregroundStyle(ms == nil ? WgInk.ink3 : (ms == 0 ? WgInk.alert : level.color))
    }
}

// MARK: - 提供商流量（O-P01）

private struct PPProviderTrafficCard: View {
    @EnvironmentObject private var panel: ProxyPanelStore

    var body: some View {
        let items = PPOverviewStore.shared.providerTraffic(panel.providers)
        if !items.isEmpty {
            PPCard(title: "提供商流量概览", caption: "Quota") {
                VStack(spacing: 12) {
                    ForEach(items) { row($0.name, used: $0.used, total: $0.total) }
                    if items.count > 1 {
                        Divider()
                        row("总计", used: items.reduce(0) { $0 + $1.used }, total: items.reduce(0) { $0 + $1.total })
                    }
                }
            }
        }
    }

    private func row(_ name: String, used: Int64, total: Int64) -> some View {
        let fraction = total > 0 ? min(1, Double(used) / Double(total)) : 0
        let fmt = ByteCountFormatter()
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(verbatim: name).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(verbatim: "已使用 \(fmt.string(fromByteCount: used)) · 剩余 \(fmt.string(fromByteCount: max(0, total - used))) · 共 \(fmt.string(fromByteCount: total))")
                    .font(WgInk.figure(11, .regular)).foregroundStyle(WgInk.ink3)
                Text(verbatim: String(format: "%.1f%%", fraction * 100))
                    .font(WgInk.mono(11, .medium))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(WgInk.rule)
                    Rectangle().fill(fraction > 0.9 ? WgInk.alert : (fraction > 0.75 ? WgInk.warn : WgInk.ink2))
                        .frame(width: geo.size.width * fraction)
                }
            }
            .frame(height: 3)
        }
    }
}

// MARK: - 连接拓扑（O-T01…O-T05）

private struct PPTopologyCard: View {
    @ObservedObject private var overview = PPOverviewStore.shared
    @State private var paused = false
    @State private var fullScreen = false
    @State private var frozen: PPSankeyModel?

    private var model: PPSankeyModel {
        frozen ?? PPSankeyModel.build(from: overview.topologyConnections, label: { $0 })
    }

    var body: some View {
        let m = model
        PPCard(title: "连接拓扑", caption: "Topology · \(overview.topologyConnections.count) conn") {
            HStack(spacing: 2) {
                Button { togglePause() } label: { Image(systemName: paused ? "play.fill" : "pause.fill") }
                    .buttonStyle(WgToolbarIconButtonStyle(isActive: paused))
                    .help(paused ? "继续" : "暂停")
                Button { fullScreen = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(WgToolbarIconButtonStyle())
                    .help("全屏")
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if m.nodes.isEmpty {
                    Text("暂无数据").font(.system(size: 12)).foregroundStyle(WgInk.ink3).frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    PPSankeyView(model: m, onHoverChange: { overview.topologyPaused = $0 || paused })
                        .equatable()
                        .frame(height: height(for: m))
                }
            }
        }
        .sheet(isPresented: $fullScreen) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("连接拓扑").font(.system(size: 17, weight: .bold))
                    Spacer()
                    Button("完成") { fullScreen = false }.keyboardShortcut(.defaultAction)
                }
                PPSankeyView(model: model, onHoverChange: { overview.topologyPaused = $0 || paused }, labelLimit: 45)
            }
            .padding(20)
            .frame(minWidth: 1100, minHeight: 760)
        }
    }

    private func height(for m: PPSankeyModel) -> CGFloat {
        let maxPerLayer = Dictionary(grouping: m.nodes, by: \.layer).values.map(\.count).max() ?? 0
        return min(900, max(260, CGFloat(maxPerLayer) * 22 + PPSankeyView.headerHeight))
    }

    private func togglePause() {
        paused.toggle()
        frozen = paused ? model : nil
        overview.topologyPaused = paused
    }
}

// MARK: - 连接统计（O-H01…O-H05）

private struct PPHistoryCard: View {
    @ObservedObject private var overview = PPOverviewStore.shared
    @State private var confirmClear = false
    @State private var sortOrder: [KeyPathComparator<PPHistoryRow>] = PPHistoryCard.savedSort()

    private static func savedSort() -> [KeyPathComparator<PPHistoryRow>] {
        let raw = UserDefaults.standard.string(forKey: "pp.historySort") ?? "download"
        switch raw {
        case "upload": return [KeyPathComparator(\PPHistoryRow.upload, order: .reverse)]
        case "total": return [KeyPathComparator(\PPHistoryRow.total, order: .reverse)]
        case "count": return [KeyPathComparator(\PPHistoryRow.count, order: .reverse)]
        case "key": return [KeyPathComparator(\PPHistoryRow.key)]
        default: return [KeyPathComparator(\PPHistoryRow.download, order: .reverse)]
        }
    }

    var body: some View {
        let rows = (overview.history[overview.historyType] ?? []).sorted(using: sortOrder)
        PPCard(title: "连接统计", caption: "History") {
            Button { confirmClear = true } label: { Image(systemName: "trash") }
                .buttonStyle(WgToolbarIconButtonStyle())
                .help("清空连接历史")
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    Picker("聚合方式", selection: $overview.historyType) {
                        ForEach(PPHistoryType.allCases) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                    Picker("自动清理间隔", selection: $overview.cleanupInterval) {
                        ForEach(PPCleanupInterval.allCases) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                    Spacer()
                }
                .font(.system(size: 12))
                HStack(spacing: 0) {
                    summary("下载", WgFormat.size(UInt64(rows.reduce(0) { $0 + $1.download })))
                    summary("上传", WgFormat.size(UInt64(rows.reduce(0) { $0 + $1.upload })))
                    summary("总流量", WgFormat.size(UInt64(rows.reduce(0) { $0 + $1.total })))
                    summary("连接数", "\(rows.reduce(0) { $0 + $1.count })")
                }
                // 自绘表格 + 翻页：系统 Table 嵌在滚动页面里，几百行的追踪区域每帧重算（实测概览页掉帧 55%→0.5%）。
                PPHistoryTable(rows: rows, keyTitle: LocalizedStringKey(overview.historyType.columnTitle), sortOrder: $sortOrder)
                    .onChange(of: sortOrder) { _, order in
                        let key: String
                        switch order.first?.keyPath {
                        case \PPHistoryRow.upload: key = "upload"
                        case \PPHistoryRow.total: key = "total"
                        case \PPHistoryRow.count: key = "count"
                        case \PPHistoryRow.key: key = "key"
                        default: key = "download"
                        }
                        UserDefaults.standard.set(key, forKey: "pp.historySort")
                    }
                Text(verbatim: "只能统计面板打开期间的连接。记录开始时间：\(overview.historyStart?.formatted(date: .abbreviated, time: .shortened) ?? "—")")
                    .font(.system(size: 11)).foregroundStyle(WgInk.ink3)
            }
        }
        .confirmationDialog("清空连接历史", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) { overview.clearHistory() }
        } message: {
            Text("确定要清空所有连接历史数据吗？此操作不可恢复。")
        }
    }

    private func summary(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(WgInk.ink2)
            WgReadout(text: value, size: 17, weight: .regular)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 规则命中统计（O-R01…O-R02）

private struct PPRuleHitsCard: View {
    @ObservedObject private var overview = PPOverviewStore.shared

    var body: some View {
        PPCard(title: "规则命中统计", caption: "Rule hits") {
            HStack(alignment: .top, spacing: 28) {
                bars(title: "命中统计", color: WgInk.ink2, hit: true)
                bars(title: "未命中统计", color: WgInk.ink3, hit: false)
            }
        }
    }

    private func bars(title: LocalizedStringKey, color: Color, hit: Bool) -> some View {
        let top = overview.rules
            .map { (rule: $0, value: hit ? $0.hitCount : $0.missCount) }
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .prefix(20)
        let rows = top.map { item in
            PPRuleBars.Row(name: item.rule.payload.isEmpty ? item.rule.type : "\(item.rule.type) · \(item.rule.payload)",
                           value: item.value,
                           at: (hit ? item.rule.hitAt : item.rule.missAt) ?? "")
        }
        return VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12, weight: .semibold)).padding(.bottom, 2)
            if rows.isEmpty {
                Text("暂无数据").font(.system(size: 11)).foregroundStyle(WgInk.ink3).frame(maxWidth: .infinity, minHeight: 60)
            } else {
                PPRuleBars(rows: rows, color: color, hit: hit)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

/// 规则命中条形图：整栏一个 Canvas + 一个悬停监听，提示框自绘。
/// 原先每行一个 GeometryReader + 系统提示，40 行在滚动时让窗口每帧遍历几十个命中区域。
private struct PPRuleBars: View {
    struct Row: Equatable { var name: String; var value: Int; var at: String }
    var rows: [Row]
    var color: Color
    var hit: Bool
    @State private var hover: Int?

    static let rowHeight: CGFloat = 25
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()

    var body: some View {
        let maxValue = Double(rows.first?.value ?? 1)
        Canvas { ctx, size in
            for (i, row) in rows.enumerated() {
                let y = CGFloat(i) * Self.rowHeight
                let focused = hover == i
                ctx.draw(Text(verbatim: String(format: "%02d", i + 1)).font(WgInk.mono(9.5)).foregroundColor(Color.primary.opacity(0.22)),
                         at: CGPoint(x: 0, y: y + 7), anchor: .leading)
                let valueText = ctx.resolve(Text("\(row.value)").font(WgInk.figure(11)).foregroundColor(Color.primary.opacity(0.64)))
                let valueSize = valueText.measure(in: size)
                ctx.draw(valueText, at: CGPoint(x: size.width, y: y + 7), anchor: .trailing)
                let nameWidth = size.width - 24 - valueSize.width - 8
                let name = PPNodeCard.truncate(row.name, font: .systemFont(ofSize: 11), width: nameWidth)
                ctx.draw(Text(verbatim: name).font(.system(size: 11)).foregroundColor(focused ? WgInk.signal : .primary),
                         at: CGPoint(x: 24, y: y + 7), anchor: .leading)
                let barRect = CGRect(x: 24, y: y + 16, width: size.width - 24, height: 2)
                ctx.fill(Path(barRect), with: .color(WgInk.rule))
                let w = max(2, barRect.width * CGFloat(Double(row.value) / maxValue))
                ctx.fill(Path(CGRect(x: barRect.minX, y: barRect.minY, width: w, height: 2)), with: .color(focused ? WgInk.signal : color))
            }
        }
        .frame(height: CGFloat(rows.count) * Self.rowHeight)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                let i = Int(p.y / Self.rowHeight)
                hover = rows.indices.contains(i) ? i : nil
            case .ended: hover = nil
            }
        }
        .overlay(alignment: .topLeading) {
            if let i = hover, rows.indices.contains(i) {
                let row = rows[i]
                let at = PPPersist.parseDate(row.at).map { Self.fmt.string(from: $0) } ?? "—"
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: row.name).font(.system(size: 11, weight: .medium)).lineLimit(2)
                    Text(verbatim: "\(hit ? "命中" : "未命中")  \(row.value) 次").font(WgInk.mono(10)).foregroundStyle(WgInk.ink2)
                    Text(verbatim: "\(hit ? "最后命中" : "最后未命中")  \(at)").font(WgInk.mono(10)).foregroundStyle(WgInk.ink3)
                }
                .padding(.horizontal, 9).padding(.vertical, 7)
                .frame(maxWidth: 300, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).strokeBorder(WgInk.rule))
                .offset(x: 24, y: CGFloat(i + 1) * Self.rowHeight)
                .allowsHitTesting(false)
            }
        }
        .zIndex(hover == nil ? 0 : 1)
    }
}

// MARK: - 卡片设置（O-C01）

private struct PPCardSettings: View {
    @ObservedObject private var overview = PPOverviewStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("卡片设置").font(.system(size: 13, weight: .semibold)).padding(12)
            Divider()
            List {
                ForEach($overview.cards) { $setting in
                    HStack(spacing: 10) {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                        Image(systemName: setting.card.symbol).font(.system(size: 11)).foregroundStyle(WgInk.ink2).frame(width: 18)
                        Text(setting.card.title).font(.system(size: 12)).foregroundStyle(setting.visible ? WgInk.ink : WgInk.ink3)
                        Spacer()
                        Toggle("", isOn: $setting.visible).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    }
                }
                .onMove { overview.cards.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.plain)
            .frame(width: 280, height: 260)
        }
    }
}

/// 连接统计表：表头可排序（再点一次反转），数据行整页一个 Canvas，翻页浏览。
private struct PPHistoryTable: View {
    var rows: [PPHistoryRow]
    var keyTitle: LocalizedStringKey
    @Binding var sortOrder: [KeyPathComparator<PPHistoryRow>]
    @State private var page = 0

    static let pageSize = 20
    static let rowHeight: CGFloat = 24
    private static let numberColumns: [CGFloat] = [96, 96, 96, 70]

    private var pageCount: Int { max(1, Int(ceil(Double(rows.count) / Double(Self.pageSize)))) }

    var body: some View {
        let current = min(page, pageCount - 1)
        let slice = Array(rows.dropFirst(current * Self.pageSize).prefix(Self.pageSize))
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                header(keyTitle, \PPHistoryRow.key, ascendingFirst: true).frame(maxWidth: .infinity, alignment: .leading)
                header("下载", \PPHistoryRow.download).frame(width: Self.numberColumns[0], alignment: .trailing)
                header("上传", \PPHistoryRow.upload).frame(width: Self.numberColumns[1], alignment: .trailing)
                header("总流量", \PPHistoryRow.total).frame(width: Self.numberColumns[2], alignment: .trailing)
                header("连接数", \PPHistoryRow.count).frame(width: Self.numberColumns[3], alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.14)).frame(height: 1) }

            Canvas { ctx, size in
                let cols = Self.numberColumns
                let numbersWidth = cols.reduce(0, +)
                for (i, row) in slice.enumerated() {
                    let y = CGFloat(i) * Self.rowHeight
                    if i % 2 == 1 { ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: Self.rowHeight)), with: .color(Color.primary.opacity(0.025))) }
                    let mid = y + Self.rowHeight / 2
                    let keyWidth = size.width - 20 - numbersWidth - 8
                    ctx.draw(Text(verbatim: PPNodeCard.truncate(row.key, font: .systemFont(ofSize: 11.5), width: keyWidth)).font(.system(size: 11.5)).foregroundColor(.primary),
                             at: CGPoint(x: 10, y: mid), anchor: .leading)
                    var x = size.width - 10
                    // 自右向左：连接数、总流量、上传、下载。
                    let texts = ["\(row.count)", WgFormat.size(UInt64(row.total)), WgFormat.size(UInt64(row.upload)), WgFormat.size(UInt64(row.download))]
                    for (j, text) in texts.enumerated() {
                        ctx.draw(Text(verbatim: text).font(WgInk.figure(11.5, .regular)).foregroundColor(Color.primary.opacity(j == 0 ? 0.64 : 0.86)),
                                 at: CGPoint(x: x, y: mid), anchor: .trailing)
                        x -= cols[cols.count - 1 - j]
                    }
                }
            }
            .frame(height: CGFloat(max(1, slice.count)) * Self.rowHeight)

            if rows.isEmpty {
                Text("暂无数据").font(.system(size: 11)).foregroundStyle(WgInk.ink3).frame(maxWidth: .infinity, minHeight: 60)
            }
            if pageCount > 1 {
                HStack(spacing: 10) {
                    Spacer()
                    Button { page = max(0, current - 1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(WgToolbarIconButtonStyle()).disabled(current == 0)
                    Text(verbatim: "\(current + 1) / \(pageCount)").font(WgInk.mono(10.5)).foregroundStyle(WgInk.ink2)
                    Button { page = min(pageCount - 1, current + 1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(WgToolbarIconButtonStyle()).disabled(current >= pageCount - 1)
                }
                .padding(.top, 8)
            }
        }
        .overlay(Rectangle().strokeBorder(WgInk.rule))
        .onChange(of: sortOrder) { _, _ in page = 0 }
    }

    private func header<V: Comparable>(_ title: LocalizedStringKey, _ path: KeyPath<PPHistoryRow, V>, ascendingFirst: Bool = false) -> some View {
        let active = sortOrder.first?.keyPath == path
        let ascending = sortOrder.first?.order == .forward
        return Button {
            let order: SortOrder = active ? (ascending ? .reverse : .forward) : (ascendingFirst ? .forward : .reverse)
            sortOrder = [KeyPathComparator(path, order: order)]
        } label: {
            HStack(spacing: 3) {
                Text(title).font(.system(size: 11, weight: active ? .semibold : .regular))
                if active { Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)) }
            }
            .foregroundStyle(active ? WgInk.signal : WgInk.ink2)
        }
        .buttonStyle(.plain)
    }
}
