import AppKit
import SwiftUI

// 代理面板基础组件：延迟标签、延迟点/条预览、节点链、节点卡片、组图标、右键动作。

// MARK: - 延迟配色

extension ProxyPanelStore.LatencyLevel {
    var color: Color {
        switch self {
        case .none: return .secondary
        case .low: return .green
        case .medium: return .yellow
        case .high: return .red
        }
    }
    /// 预览点的底色（未连通用中性灰，与原版 bg-base-content/60 对应）。
    var dotColor: Color {
        switch self {
        case .none: return Color.secondary.opacity(0.55)
        case .low: return .green
        case .medium: return .yellow
        case .high: return .red
        }
    }
}

// MARK: - 右键直接触发（原版右键卡片 = 测速，不弹菜单）

private struct RightClickCatcher: NSViewRepresentable {
    var action: () -> Void

    final class CatcherView: NSView {
        var action: (() -> Void)?
        override func rightMouseDown(with event: NSEvent) { action?() }
        // 只拦截右键，其余事件穿透给 SwiftUI。
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let type = NSApp.currentEvent?.type,
                  type == .rightMouseDown || type == .rightMouseUp else { return nil }
            return super.hitTest(point)
        }
    }

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) { view.action = action }
}

extension View {
    func onRightClick(_ action: @escaping () -> Void) -> some View {
        overlay(RightClickCatcher(action: action))
    }
}

// MARK: - 延迟标签（P-G06 · P-G07 · P-N03）

struct PPLatencyTag: View {
    @EnvironmentObject private var store: ProxyPanelStore
    var name: String?
    var group: String?
    var loading: Bool
    var small = false
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        let latency = name.map { store.latency($0, group: group) } ?? mihomoNotConnected
        let level = store.level(latency)
        Button(action: action) {
            ZStack {
                if loading {
                    ProgressView().controlSize(.mini)
                } else if latency == mihomoNotConnected {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(latency)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(level.color)
                        .contentTransition(.numericText(value: Double(latency)))
                }
            }
            .frame(width: small ? 32 : 40, height: small ? 16 : 20)
            .background(Capsule().fill(Color.primary.opacity(hovering ? 0.12 : 0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.6), value: latency)
        .help(historyTip)
    }

    /// 悬停显示测速历史（时间 + 延迟）。
    private var historyTip: String {
        guard let name else { return "" }
        let items = store.history(name, group: group)
        guard !items.isEmpty else { return "测速" }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return items.suffix(10).map { item in
            let time = PPPersist.parseDate(item.time).map { fmt.string(from: $0) } ?? item.time
            return "\(time)  \(item.delay == 0 ? "超时" : "\(item.delay)ms")"
        }.joined(separator: "\n")
    }
}

// MARK: - 预览（P-G09）

struct PPPreview: View {
    @EnvironmentObject private var store: ProxyPanelStore
    var nodes: [String]
    var now: String?
    var group: String?
    var onSelect: (String) -> Void

    @State private var width: CGFloat = 0

    var body: some View {
        let showDots: Bool = {
            switch store.previewType {
            case .dots: return true
            case .bar: return false
            case .auto: return width == 0 || width > CGFloat(20 * nodes.count)
            }
        }()
        Group {
            if showDots {
                PPFlowLayout(spacing: 4) {
                    ForEach(nodes, id: \.self) { node in
                        let latency = store.latency(node, group: group)
                        PPDot(color: store.level(latency).dotColor, isCurrent: node == now,
                              tip: latency == 0 ? node : "\(node)  \(latency)ms") { onSelect(node) }
                    }
                }
            } else {
                barView
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { geo in
            Color.clear.onAppear { width = geo.size.width }
                .onChange(of: geo.size.width) { _, w in width = w }
        })
    }

    private var barView: some View {
        let levels = nodes.map { store.level(store.latency($0, group: group)) }
        let total = max(levels.count, 1)
        let counts: [(ProxyPanelStore.LatencyLevel, Int)] = [
            (.low, levels.filter { $0 == .low }.count),
            (.medium, levels.filter { $0 == .medium }.count),
            (.high, levels.filter { $0 == .high }.count),
            (.none, levels.filter { $0 == .none }.count),
        ]
        return GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(counts, id: \.0) { level, count in
                    level.dotColor.frame(width: geo.size.width * CGFloat(count) / CGFloat(total))
                }
            }
        }
        .frame(height: 6)
        .clipShape(Capsule())
    }
}

/// 延迟点：纯值输入，不订阅数据源（上层算好颜色传入），避免任何数据变化都让几百个点一起重算。
private struct PPDot: View, Equatable {
    var color: Color
    var isCurrent: Bool
    var tip: String
    var action: () -> Void
    @State private var hovering = false

    static func == (a: PPDot, b: PPDot) -> Bool {
        a.color == b.color && a.isCurrent == b.isCurrent && a.tip == b.tip
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 12, height: 12)
            .overlay {
                if isCurrent { Circle().fill(Color.white).frame(width: 5, height: 5) }
            }
            .scaleEffect(hovering ? 1.15 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .help(tip)
    }
}

/// 组下载速度：唯一订阅每秒变化统计的视图。
struct PPGroupSpeed: View {
    @ObservedObject private var live = PPLiveStats.shared
    var group: String
    var body: some View {
        Text(verbatim: WgFormat.speed(Double(live.groupDownloadSpeed[group] ?? 0)))
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
    }
}

/// 自动换行布局（预览点、节点链等）。
struct PPFlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - 节点链（P-G03 · P-G04 · P-G05）

struct PPRouteView: View {
    @EnvironmentObject private var store: ProxyPanelStore
    var group: String
    var forceFull = false

    var body: some View {
        let proxy = store.proxyMap[group]
        HStack(spacing: 4) {
            if let proxy, proxy.now != nil {
                if store.isFixed(group) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .help("当前策略组被固定在了当前节点，点击测速来恢复 \(proxy.type) 行为")
                }
                let names = (store.displayFinalOutbound || forceFull) ? store.routeChain(group) : [proxy.now!]
                ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                    if index > 0 {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    Text(verbatim: name)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else if proxy?.type.lowercased() == "loadbalance" {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("负载均衡")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}

// MARK: - 组图标

struct PPGroupIcon: View {
    var icon: String?
    var size: CGFloat

    var body: some View {
        if let icon, let url = URL(string: icon), url.scheme?.hasPrefix("http") == true {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                Color.clear
            }
            .frame(width: size, height: size)
        } else if let icon, icon.hasPrefix("data:image"),
                  let data = Data(base64Encoded: String(icon.split(separator: ",").last ?? "")),
                  let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFit().frame(width: size, height: size)
        }
    }
}

// MARK: - 节点卡片（P-N01…P-N08）

struct PPNodeCard: View {
    @EnvironmentObject private var store: ProxyPanelStore
    var name: String
    var group: String
    var active: Bool

    @State private var hovering = false
    @State private var flash = false

    var body: some View {
        let node = store.proxyMap[name]
        let testing = store.isTesting("node:\(group)/\(name)")
        VStack(alignment: .leading, spacing: store.smallCard ? 3 : 6) {
            HStack(spacing: 4) {
                PPGroupIcon(icon: node?.icon, size: 14)
                Text(verbatim: name)
                    .font(.system(size: store.smallCard ? 12 : 13, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Color.white : Color.primary)
                    .lineLimit(store.truncateProxyName ? 1 : 3)
                    .truncationMode(.tail)
                    .help(name)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Text(verbatim: typeDescription(node))
                    .font(.system(size: 10.5))
                    .foregroundStyle(active ? Color.white.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                PPLatencyTag(name: name, group: group, loading: testing, small: store.smallCard) {
                    test()
                }
            }
        }
        .padding(store.smallCard ? 7 : 10)
        .frame(minWidth: store.minProxyCardWidth, maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(active ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.10 : 0.055)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(flash ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.06), lineWidth: flash ? 2 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { Task { await store.select(group: group, node: name) } }
        .onRightClick { test() }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.3), value: active)
    }

    private func test() {
        Task {
            await store.testNode(name, group: group)
            // P-N07：按延迟排序时，测完闪烁提示位置。
            if store.sortType == .latencyasc || store.sortType == .latencydesc {
                flash = true
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                flash = false
            }
        }
    }

    /// P-N02：协议简写 / udp|xudp / Smart 使用频率 / IPv6。
    private func typeDescription(_ node: MihomoProxy?) -> String {
        guard let node else { return "" }
        var type = node.type.lowercased()
        type = type.replacingOccurrences(of: "shadowsocks", with: "ss")
            .replacingOccurrences(of: "hysteria", with: "hy")
            .replacingOccurrences(of: "wireguard", with: "wg")
        let udp = node.udp ? (node.xudp ? "xudp" : "udp") : ""
        let smart: String = {
            switch store.smartWeights[group]?[name] {
            case "MostUsed": return "经常使用"
            case "OccasionalUsed": return "偶尔使用"
            case "RarelyUsed": return "很少使用"
            default: return ""
            }
        }()
        let v6 = store.ipv6Test && (store.ipv6Map[name] ?? false) ? "IPv6" : ""
        return [type, udp, smart, v6].filter { !$0.isEmpty }.joined(separator: store.smallCard ? "/" : " / ")
    }
}

/// 节点卡片网格：按最小宽度自适应列数。
struct PPNodeGrid: View {
    @EnvironmentObject private var store: ProxyPanelStore
    var group: String
    var names: [String]

    var body: some View {
        let now = store.proxyMap[group]?.now
        LazyVGrid(columns: [GridItem(.adaptive(minimum: store.minProxyCardWidth), spacing: 8)], spacing: 8) {
            ForEach(names, id: \.self) { name in
                PPNodeCard(name: name, group: group, active: name == now)
            }
        }
    }
}
