import SwiftUI

// MARK: - 代理管理主页面（复刻 AnGe-ClashBoard 全功能）
struct ProxyView: View {
    @EnvironmentObject var client: DaemonClient
    @State private var subTab: ProxySubTab = .proxyGroups

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            proxyTabBar
            Divider().opacity(0.15)

            Group {
                switch subTab {
                case .proxyGroups: ProxyGroupsPage()
                case .domainGroups: DomainGroupsPage()
                case .nodes: NodesPage()
                case .subscriptions: SubscriptionsPage()
                case .rules: RulesPage()
                }
            }
        }
        .task(id: subTab) { await refreshForTab(subTab) }
    }

    // MARK: 头部
    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe.asia.australia")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.purple)
            Text("代理管理").font(.title2).fontWeight(.semibold)
            Spacer()

            if client.proxyRunning {
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text(client.mihomoVersion?.version ?? "Mihomo")
                        .font(.caption).foregroundStyle(.secondary)
                    if !client.proxyAddress.isEmpty {
                        Text("@\(client.proxyAddress)").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.green.opacity(0.08)).clipShape(Capsule())
            } else {
                HStack(spacing: 4) {
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                    Text("离线").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.red.opacity(0.08)).clipShape(Capsule())
            }
        }
        .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 14)
    }

    // MARK: 子 Tab 栏
    private var proxyTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(ProxySubTab.allCases) { tab in
                    Button { withAnimation(.easeInOut(duration: 0.2)) { subTab = tab } } label: {
                        HStack(spacing: 5) {
                            Image(systemName: tab.icon).font(.system(size: 11, weight: .semibold))
                            Text(tab.label).font(.subheadline)
                                .fontWeight(subTab == tab ? .semibold : .regular)
                        }
                        .foregroundStyle(subTab == tab ? WgTheme.accent : .secondary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(subTab == tab ? WgTheme.accent.opacity(0.1) : Color.clear))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
        }.padding(.horizontal, 28).padding(.vertical, 8)
    }

    private func refreshForTab(_ tab: ProxySubTab) async {
        await client.fetchProxyStatus()
        switch tab {
        case .proxyGroups, .domainGroups, .nodes:
            if client.proxyRunning { await client.fetchProxies() }
        case .rules:
            if client.proxyRunning { await client.fetchRules() }
        case .subscriptions: break
        }
    }
}

// MARK: 子 Tab 枚举（5 个 tab：策略 | 域名 | 节点 | 订阅 | 规则）
enum ProxySubTab: String, CaseIterable, Identifiable {
    case proxyGroups, domainGroups, nodes, subscriptions, rules
    var id: String { rawValue }

    var label: String {
        switch self {
        case .proxyGroups: return "策略"
        case .domainGroups: return "域名"
        case .nodes: return "节点"
        case .subscriptions: return "订阅"
        case .rules: return "规则"
        }
    }

    var icon: String {
        switch self {
        case .proxyGroups: return "square.grid.2x2"
        case .domainGroups: return "globe"
        case .nodes: return "circle.grid.3x3"
        case .subscriptions: return "link"
        case .rules: return "scroll.text.circles"
        }
    }
}

// MARK: 策略组页面（节点选择型：手动/Smart/Fallback）
struct ProxyGroupsPage: View {
    @EnvironmentObject var client: DaemonClient
    @State private var searchText = ""
    @State private var delayResults: [String: Int64] = [:]
    @State private var isTesting = false

    // 只显示节点选择型策略组：名字含"手动"/地区名/Fallback/Smart，不含应用域名穿透
    private var groupProxies: [(String, DaemonClient.ProxyInfo)] {
        client.proxies.filter { isNodeGroup($0.0, $0.1) }
            .sorted { priorityOrder($0.key) < priorityOrder($1.key) }
    }

    private var filteredGroups: [(String, DaemonClient.ProxyInfo)] {
        if searchText.isEmpty { return groupProxies }
        return groupProxies.filter { $0.0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar(count: groupProxies.count, title: "策略")
            Divider().opacity(0.1)

            if filteredGroups.isEmpty {
                emptyView("暂无策略组", icon: "square.grid.2x2")
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredGroups, id: \.0) { name, info in
                            ProxyGroupCard(
                                groupName: name, info: info,
                                allProxies: client.proxies,
                                delayResults: delayResults,
                                onSelectNode: { node in
                                    Task {
                                        let ok = await client.selectProxy(group: name, name: node)
                                        if ok { await client.fetchProxies() }
                                    }
                                },
                                onTestDelay: { node in Task { await testNode(node) } },
                                onTestGroup: { Task { await testGroup(name) } })
                        }
                    }.padding(.horizontal, 20).padding(.vertical, 12)
                }
            }
        }
        .task {
            if delayResults.isEmpty { await testAllNodes() }
        }
    }

    /// 判断是否为「策略」tab — 域名穿透型 Selector
    /// 匹配：应用名/域名（人工智能/流媒体/谷歌/YouTube/X/微软/GitHub 等）
    private func isNodeGroup(_ name: String, _ info: DaemonClient.ProxyInfo) -> Bool {
        guard isGroupType(info.type) else { return false }
        let lower = name.lowercased()
        let systemGroups = ["global","direct","reject"]
        for sg in systemGroups { if lower == sg { return false } }
        // 排除地区型（归「域名」tab）
        let regionKeywords = ["香港","日本","美国","新加坡","台湾","韩国","英国","德国",
            "hk ","japan","us ","singapore","taiwan","korea"]
        for kw in regionKeywords { if lower.contains(kw.lowercased()) { return false } }
        if lower.hasPrefix("所有") { return false }
        // 域名穿透关键词 → 策略 tab
        let kwds = ["github","youtube","yt ","谷歌","google","微软","microsoft","apple",
            "openai","chatgpt","netflix","流媒体","人工智能","人工","智能",
            "英伟达","nvidia","加密货币","游戏","测试","颜色",
            "dia","diabrowser","国内","国外","twitter","telegram","x ","微軟"]
        for k in kwds { if lower.contains(k.lowercased()) { return true } }
        // 排除：其他-xxx 归域名 tab
        if lower.hasPrefix("其他") { return false }
        return true // 兜底：其余 Selector 归策略
    }

    private func isGroupType(_ type: String) -> Bool {
        ["Selector","Fallback","URLTest","LoadBalance","Smart"].contains(type)
    }

    private func priorityOrder(_ key: String) -> Int {
        let order = ["GLOBAL","节点选择","\u{1F1ED}\u{1F1F0} 香港","\u{1F1EF}\u{1F1F5} 日本","\u{1F1FA}\u{1F1F8} 美国","\u{1F1F8}\u{1F1EC} 新加坡","\u{1F1F9}\u{1F1FC} 台湾"]
        if let idx = order.firstIndex(of: key) { return idx }
        return Int.max
    }

    /// 测试所有可见组的全部叶子节点延迟
    private func testAllNodes() async {
        guard !isTesting else { return }
        isTesting = true
        defer { isTesting = false }
        // 收集所有叶子节点名
        var allLeafNodes: Set<String> = []
        for (_, info) in groupProxies {
            if let nodes = info.all { allLeafNodes.formUnion(nodes) }
        }
        // 逐个测试（并发控制：每批8个）
        let batch = Array(allLeafNodes)
        for i in stride(from: 0, to: batch.count, by: 8) {
            let slice = batch[i..<min(i+8, batch.count)]
            await withTaskGroup(of: (String, Int64?).self) { group in
                for name in slice {
                    group.addTask {
                        if let r = await self.client.testDelay(name: name) {
                            return (name, r.delay)
                        }
                        return (name, nil)
                    }
                }
                for await (name, delay) in group {
                    if let d = delay { delayResults[name] = d }
                }
            }
        }
    }

    private func testNode(_ nodeName: String) async {
        if let result = await client.testDelay(name: nodeName) { delayResults[nodeName] = result.delay }
    }

    private func testGroup(_ groupName: String) async {
        _ = await client.testGroupDelay(group: groupName)
        // 测试该组所有节点
        if let nodes = client.proxies[groupName]?.all {
            for n in nodes { if let r = await client.testDelay(name: n) { delayResults[n] = r.delay } }
        }
    }

    private func updateAllProviders() async {
        for (_, info) in groupProxies {
            if let provider = info.provider, !provider.isEmpty {
                _ = await client.updateProvider(name: provider)
            }
        }
        await client.fetchProxies()
    }

    @ViewBuilder
    private func toolbar(count: Int, title: String) -> some View {
        HStack(spacing: 8) {
            Text("\(title) (\(count))").font(.subheadline).fontWeight(.semibold).foregroundStyle(WgTheme.accent)
            Spacer()
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").font(.caption2).foregroundStyle(.tertiary)
                TextField("搜索 | 多个关键词用空格分隔", text: $searchText)
                    .textFieldStyle(.plain).font(.caption)
            }.padding(.horizontal, 8).padding(.vertical, 5)
                .background(WgTheme.cardBg).clipShape(RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: 240)
            Button(action: { Task { await testAllNodes() } }) {
                Image(systemName: isTesting ? "arrow.triangle.2.circlepath" : "stopwatch.fill")
                    .font(.system(size: 13)).foregroundStyle(isTesting ? .orange : .secondary)
            }.buttonStyle(.plain).disabled(isTesting)
            Button(action: { Task { await updateAllProviders() } }) {
                Image(systemName: "arrow.clockwise").font(.system(size: 13)).foregroundStyle(.secondary)
            }.buttonStyle(.plain)
            Button(action: { Task { await client.fetchProxies() } }) {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 13)).foregroundStyle(.secondary)
            }.buttonStyle(.plain)
        }.padding(.horizontal, 20).padding(.vertical, 10)
    }

    @ViewBuilder
    private func emptyView(_ msg: String, icon: String) -> some View {
        Spacer()
        VStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 44))
                .foregroundStyle(.secondary.opacity(0.3))
            Text(client.proxyRunning ? msg : "代理服务未连接")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        Spacer()
    }
}

// MARK: 域名策略组页面（域名穿透型）
struct DomainGroupsPage: View {
    @EnvironmentObject var client: DaemonClient
    @State private var searchText = ""
    @State private var expandedGroup: String? = nil

    private var domainProxies: [(String, DaemonClient.ProxyInfo)] {
        client.proxies.filter { isDomainGroup($0.0, $0.1) }
            .sorted { $0.key < $1.key }
    }

    private var filtered: [(String, DaemonClient.ProxyInfo)] {
        if searchText.isEmpty { return domainProxies }
        return domainProxies.filter { $0.0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("域名 (\(domainProxies.count))").font(.subheadline).fontWeight(.semibold).foregroundStyle(WgTheme.accent)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.caption2).foregroundStyle(.tertiary)
                    TextField("搜索域名策略\u{2026}", text: $searchText)
                        .textFieldStyle(.plain).font(.caption)
                }.padding(.horizontal, 8).padding(.vertical, 5)
                    .background(WgTheme.cardBg).clipShape(RoundedRectangle(cornerRadius: 6))
            }.padding(.horizontal, 20).padding(.vertical, 10)
            Divider().opacity(0.1)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filtered, id: \.0) { name, info in
                        DomainGroupRow(
                            name: name, info: info,
                            allProxies: client.proxies,
                            isExpanded: expandedGroup == name,
                            onSelect: { target in
                                Task {
                                    let ok = await client.selectProxy(group: name, name: target)
                                    if ok { await client.fetchProxies(); expandedGroup = nil }
                                }
                            },
                            onToggle: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    expandedGroup = (expandedGroup == name) ? nil : name
                                }
                            })
                    }
                }.padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
    }

    /// 判断是否为「域名」tab — 地区节点选择型组
    /// 匹配：地区名（香港/台湾/日本/美国/新加坡）+ 所有/手动 + Fallback/Smart
    private func isDomainGroup(_ name: String, _ info: DaemonClient.ProxyInfo) -> Bool {
        guard ["Selector","Fallback","URLTest","LoadBalance","Smart"].contains(info.type) else { return false }
        let lower = name.lowercased()
        let systemGroups = ["global","direct","reject"]
        for sg in systemGroups { if lower == sg { return false } }
        // 地区关键词 → 域名 tab
        let regionKeywords = [
            "香港","日本","美国","新加坡","台湾","韩国","英国","德国",
            "hk ","japan","us ","singapore","taiwan","korea"
        ]
        for kw in regionKeywords { if lower.contains(kw.lowercased()) { return true } }
        if lower.hasPrefix("所有") { return true }
        // Fallback/Smart 也归域名 tab（如 香港-故转、所有-自动）
        if info.type == "Fallback" || info.type == "Smart" || info.type == "URLTest" { return true }
        // 其他-xxx 归域名 tab
        if lower.hasPrefix("其他") { return true }
        return false
    }
}

// MARK: 域名策略行（点击展开子选项列表）
struct DomainGroupRow: View {
    let name: String
    let info: DaemonClient.ProxyInfo
    let allProxies: [String: DaemonClient.ProxyInfo]
    let isExpanded: Bool
    let onSelect: (String) -> Void
    let onToggle: () -> Void

    private var subOptions: [(String, DaemonClient.ProxyInfo?)] {
        guard let all = info.all else { return [] }
        return all.map { opt in (opt, allProxies[opt]) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    Text(domainIcon(name)).font(.title3)
                        .frame(width: 28, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.subheadline).fontWeight(.semibold).lineLimit(1)
                        HStack(spacing: 4) {
                            Text("Selector").font(.system(size: 9)).foregroundStyle(.blue.opacity(0.7))
                            Text(info.now ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isExpanded ? WgTheme.accent : .secondary)
                        .frame(width: 14)
                }
                .padding(.vertical, 10).padding(.horizontal, 12)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)

            if isExpanded {
                ForEach(subOptions, id: \.0) { optName, optInfo in
                    Button(action: { onSelect(optName) }) {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill((info.now == optName) ? WgTheme.accent : Color.clear)
                                .frame(width: 3, height: 16)
                            Text(optName).font(.caption)
                                .foregroundStyle((info.now == optName) ? .primary : .secondary)
                                .lineLimit(1)
                            Spacer()
                            if let t = optInfo?.type, !t.isEmpty {
                                Text(t).font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 6).padding(.horizontal, 12).padding(.leading, 8)
                        .background((info.now == optName) ? WgTheme.accent.opacity(0.06) : Color.clear)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
        }
        .background(WgTheme.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(WgTheme.cardBorder.opacity(0.3), lineWidth: 0.5))
    }

    private func domainIcon(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("youtube") || lower.contains("yt ") { return "\u{1F3AC}" }
        if lower.contains("谷歌") || lower.contains("google") { return "\u{1F0E0}" }
        if lower.contains("微软") || lower.contains("microsoft") { return "\u{1F3AF}" }
        if lower.contains("苹果") || lower.contains("apple") { return "\u{1F34E}" }
        if lower.contains("github") { return "\u{1F4BB}" }
        if lower.contains("openai") || lower.contains("chatgpt") { return "\u{1F9E0}" }
        if lower.contains("netflix") || lower.contains("流媒体") { return "\u{1F3AC}" }
        if lower.contains("英伟达") || lower.contains("nvidia") { return "\u{1F3AF}" }
        if lower.contains("游戏") { return "\u{1F3AE}" }
        if lower.contains("telegram") { return "\u{1F4E8}" }
        if lower.contains("twitter") || lower.contains("x ") { return "\u{1F426}" }
        if lower.contains("国内") { return "\u{1F1E8}\u{1F1F3}" }
        if lower.contains("人工") || lower.contains("智能") { return "\u{1F9E0}" }
        return "\u{1F310}"
    }
}

// MARK: 节点平铺页面（截图2风格）
struct NodesPage: View {
    @EnvironmentObject var client: DaemonClient
    @State private var searchText = ""

    private var allNodes: [(String, DaemonClient.ProxyInfo)] {
        client.proxies.filter { !["Selector","Fallback","URLTest","LoadBalance","Smart"].contains($0.value.type) }
            .sorted { $0.key < $1.key }
    }

    private var filtered: [(String, DaemonClient.ProxyInfo)] {
        if searchText.isEmpty { return allNodes }
        return allNodes.filter { $0.0.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("节点 (\(allNodes.count))").font(.subheadline).fontWeight(.semibold).foregroundStyle(WgTheme.accent)
                Spacer()
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").font(.caption2).foregroundStyle(.tertiary)
                    TextField("搜索节点\u{2026}", text: $searchText)
                        .textFieldStyle(.plain).font(.caption)
                }.padding(.horizontal, 8).padding(.vertical, 5)
                    .background(WgTheme.cardBg).clipShape(RoundedRectangle(cornerRadius: 6))
            }.padding(.horizontal, 20).padding(.vertical, 10)

            Divider().opacity(0.1)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filtered, id: \.0) { name, info in
                        NodeTileRow(name: name, info: info)
                    }
                }.padding(.horizontal, 20).padding(.vertical, 12)
            }
        }
    }
}

// MARK: 策略组磁贴卡片（复刻 Clash Verge 风格）
struct ProxyGroupCard: View {
    let groupName: String
    let info: DaemonClient.ProxyInfo
    let allProxies: [String: DaemonClient.ProxyInfo]
    let delayResults: [String: Int64]
    let onSelectNode: (String) -> Void
    let onTestDelay: (String) -> Void
    let onTestGroup: () -> Void
    @State private var isExpanded = false

    private var nodes: [(String, DaemonClient.ProxyInfo?)] {
        guard let all = info.all else { return [] }
        return all.map { n in (n, allProxies[n]) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 卡片头部：图标 + 组名 + 类型标签 + 延迟 + 速度
            HStack(spacing: 10) {
                // 图标/emoji
                Group {
                    if groupName.contains("\u{1F1ED}\u{1F1F0}") || groupName.contains("香港") { Text("\u{1F1ED}\u{1F1F0}").font(.title2) }
                    else if groupName.contains("\u{1F1EF}\u{1F1F5}") || groupName.contains("日本") { Text("\u{1F1EF}\u{1F1F5}").font(.title2) }
                    else if groupName.contains("\u{1F1FA}\u{1F1F8}") || groupName.contains("美国") { Text("\u{1F1FA}\u{1F1F8}").font(.title2) }
                    else if groupName.contains("\u{1F1F8}\u{1F1EC}") || groupName.contains("新加坡") { Text("\u{1F1F8}\u{1F1EC}").font(.title2) }
                    else if groupName.contains("\u{1F1F9}\u{1F1FC}") || groupName.contains("台湾") { Text("\u{1F1F9}\u{1F1FC}").font(.title2) }
                    else if groupName.contains("人工") || groupName.contains("AI") { Text("\u{1F9E0}").font(.title2) }
                    else if groupName.contains("流媒体") || groupName.contains("Netflix") { Text("\u{1F3AC}").font(.title2) }
                    else if groupName.contains("谷歌") || groupName.contains("Google") { Text("\u{1F0E0}").font(.title2) }
                    else { Text("\u{1F310}").font(.title2) } // 地球默认
                }.frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(groupName).font(.subheadline).fontWeight(.semibold)
                        typeLabel(info.type)
                    }
                    HStack(spacing: 4) {
                        subTypeLabel(info.type)
                        Text(info.now ?? "").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        if let allCount = info.all?.count, allCount > 0 {
                            Text("\(allCount) 节点").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    if let d = delayResults[groupName] {
                        DelayDot(delay: d)
                    } else {
                        Text("--").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            // 节点磁贴网格布局（LazyVGrid 高性能 + 默认折叠）
            NodeGridSection(
                nodes: nodes,
                currentSelection: info.now,
                delayResults: delayResults,
                maxVisible: 12,
                onSelectNode: onSelectNode,
                onTestDelay: onTestDelay
            )
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .background(WgTheme.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(WgTheme.cardBorder.opacity(0.3), lineWidth: 0.5))
    }

    private func typeLabel(_ type: String) -> some View {
        let (text, color): (String, Color) = {
            switch type {
            case "Selector":   return ("Selector", .blue)
            case "Fallback":   return ("Fallback", .orange)
            case "URLTest":    return ("URLTest", .green)
            case "LoadBalance": return ("LoadBalance", .purple)
            case "Smart":      return ("Smart", .pink)
            default:           return (type, .gray)
            }
        }()
        return Text(text).font(.system(size: 9)).fontWeight(.medium)
            .foregroundStyle(color).opacity(0.7)
    }

    private func subTypeLabel(_ type: String) -> some View {
        let text: String = {
            switch type {
            case "Selector": return "selector"
            case "Fallback": return "fallback"
            case "URLTest": return "smart"
            case "LoadBalance": return "load-balance"
            case "Smart": return "smart"
            default: return type.lowercased()
            }
        }()
        return Text(text).font(.system(size: 9)).foregroundStyle(.tertiary)
    }
}

// MARK: 节点磁贴（大尺寸固定大小 - Clash Verge 风格）
struct NodeChip: View {
    let name: String
    let isSelected: Bool
    let delay: Int64?
    let type: String
    let onTap: () -> Void
    let onLongPress: () -> Void

    // 固定宽高比 1:0.618 (黄金比例横向) - 大尺寸
    private let chipWidth: CGFloat = 200
    private let chipHeight: CGFloat = 124

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 8) {
                // 第一行：国旗 emoji（大）+ 延迟
                HStack(alignment: .top) {
                    Text(flagEmoji(for: name)).font(.system(size: 44))
                    Spacer()
                    if let d = delay {
                        DelayDot(delay: d)
                    } else {
                        Text("--").font(.system(size: 18, weight: .medium).monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }

                // 第二行：节点名
                Text(shortName(name))
                    .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? WgTheme.accent : .primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // 第三行：类型标签
                Text(displayType(type))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(width: chipWidth, height: chipHeight)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(isSelected ?
                    WgTheme.accent.opacity(0.12) :
                    Color(nsColor: .controlColor).opacity(0.8))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? WgTheme.accent.opacity(0.5) : Color.white.opacity(0.08), lineWidth: isSelected ? 1.2 : 0.5)
            )
            .shadow(color: isSelected ? WgTheme.accent.opacity(0.15) : .clear, radius: isSelected ? 4 : 0, y: 2)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("测速延迟", systemImage: "stopwatch") { onLongPress() }
        }
    }

    private func shortName(_ full: String) -> String {
        if full.contains(" ") {
            return full.split(separator: " ").first.map(String.init) ?? full
        }
        return String(full.prefix(24))
    }

    private func displayType(_ type: String) -> String {
        switch type {
        case "ss", "ssr": return "Shadowsocks"
        case "vmess": return "VMESS"
        case "trojan": return "Trojan"
        case "vless": return "VLESS"
        case "hysteria", "hysteria2": return "Hysteria2"
        case "tuic": return "TUIC"
        case "wireguard": return "WireGuard"
        default: return type.isEmpty ? "Unknown" : type.uppercased()
        }
    }

    private func flagEmoji(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("香港") || lower.contains("hongkong") || lower.contains("hk") { return "\u{1F1ED}\u{1F1F0}" }
        if lower.contains("日本") || lower.contains("japan") || lower.contains("jp") || lower.contains("东京") { return "\u{1F1EF}\u{1F1F5}" }
        if lower.contains("美国") || lower.contains("us") || lower.contains("洛杉矶") || lower.contains("硅谷") || lower.contains("达拉斯") || lower.contains("凤凰城") || lower.contains("西雅图") || lower.contains("纽约") { return "\u{1F1FA}\u{1F1F8}" }
        if lower.contains("新加坡") || lower.contains("singapore") || lower.contains("sg") { return "\u{1F1F8}\u{1F1EC}" }
        if lower.contains("台湾") || lower.contains("taiwan") || lower.contains("tw") { return "\u{1F1F9}\u{1F1FC}" }
        if lower.contains("韩国") || lower.contains("korea") || lower.contains("kr") { return "\u{1F1F0}\u{1F1F7}" }
        if lower.contains("英国") || lower.contains("uk") || lower.contains("伦敦") { return "\u{1F1EC}\u{1F1E7}" }
        if lower.contains("德国") || lower.contains("germany") || lower.contains("de") { return "\u{1F1E9}\u{1F1EA}" }
        if lower.contains("印度") || lower.contains("india") { return "\u{1F1EE}\u{1F1F3}" }
        if lower.contains("土耳其") || lower.contains("turkey") { return "\u{1F1F9}\u{1F1F7}" }
        if lower.contains("墨西哥") || lower.contains("mexico") { return "\u{1F1F2}\u{1F1FD}" }
        if lower.contains("阿根廷") || lower.contains("argentina") { return "\u{1F1E6}\u{1F1F7}" }
        if lower.contains("直连") || lower.contains("direct") { return "\u{1F3AF}" }
        if lower.contains("拒绝") || lower.contains("reject") || lower.contains("block") { return "\u{274C}" }
        if lower.contains("自动") || lower.contains("auto") { return "\u{1F30D}" }
        return "\u{1F30D}"
    }
}

// MARK: 节点行（NodesPage 平铺用）
struct NodeTileRow: View {
    let name: String
    let info: DaemonClient.ProxyInfo

    var body: some View {
        HStack(spacing: 10) {
            Text(flagEmoji(for: name)).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline).lineLimit(1)
                HStack(spacing: 4) {
                    Text(info.type).font(.caption2).foregroundStyle(.secondary)
                    if let sub = info.now, !sub.isEmpty {
                        Text(sub).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            }
            Spacer()
        }.padding(.vertical, 7).padding(.horizontal, 4)
    }

    private func flagEmoji(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("香港") || lower.contains("hongkong") || lower.contains("hk") { return "\u{1F1ED}\u{1F1F0}" }
        if lower.contains("日本") || lower.contains("japan") || lower.contains("jp") || lower.contains("东京") { return "\u{1F1EF}\u{1F1F5}" }
        if lower.contains("美国") || lower.contains("洛杉矶") || lower.contains("硅谷") || lower.contains("达拉斯") || lower.contains("凤凰城") || lower.contains("西雅图") || lower.contains("纽约") { return "\u{1F1FA}\u{1F1F8}" }
        if lower.contains("新加坡") || lower.contains("singapore") || lower.contains("sg") { return "\u{1F1F8}\u{1F1EC}" }
        if lower.contains("台湾") || lower.contains("taiwan") || lower.contains("tw") { return "\u{1F1F9}\u{1F1FC}" }
        if lower.contains("韩国") || lower.contains("korea") || lower.contains("kr") { return "\u{1F1F0}\u{1F1F7}" }
        if lower.contains("英国") || lower.contains("uk") || lower.contains("伦敦") { return "\u{1F1EC}\u{1F1E7}" }
        if lower.contains("德国") || lower.contains("germany") { return "\u{1F1E9}\u{1F1EA}" }
        if lower.contains("土耳其") || lower.contains("turkey") { return "\u{1F1F9}\u{1F1F7}" }
        if lower.contains("墨西哥") || lower.contains("mexico") { return "\u{1F1F2}\u{1F1FD}" }
        if lower.contains("阿根廷") || lower.contains("argentina") { return "\u{1F1E6}\u{1F1F7}" }
        if lower.contains("直连") || lower.contains("direct") { return "\u{1F3AF}" }
        if lower.contains("拒绝") || lower.contains("reject") { return "\u{274C}" }
        return "\u{1F30D}"
    }
}

// MARK: 延迟圆点（复刻截图风格）
struct DelayDot: View {
    enum Size { case normal, small }
    var size: Size = .normal
    let delay: Int64

    var body: some View {
        let (text, color): (String, Color) = {
            if delay <= 0 { return ("\u{2715}", .red) }
            if delay < 200 { return ("\(delay)", .green) }
            if delay < 500 { return ("\(delay)", .yellow) }
            return ("\(delay)", .red)
        }()
        let fsize: CGFloat = size == .normal ? 10 : 9

        if delay <= 0 {
            // 叉号
            Text(text).font(.system(size: fsize)).foregroundStyle(color)
        } else {
            // 圆形背景 + 数字
            Text(text)
                .font(.system(size: fsize, weight: .medium).monospacedDigit())
                .foregroundStyle(color)
                .padding(.horizontal, size == .normal ? 6 : 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(color.opacity(0.15)))
        }
    }
}

// MARK: 节点网格区域（可展开/折叠 + LazyVGrid 高性能）
struct NodeGridSection: View {
    let nodes: [(String, DaemonClient.ProxyInfo?)]
    let currentSelection: String?
    let delayResults: [String: Int64]
    let maxVisible: Int
    let onSelectNode: (String) -> Void
    let onTestDelay: (String) -> Void
    @State private var showAll = false

    // 根据宽度自适应列数（4列配合大磁贴）
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
    }

    private var displayNodes: [(String, DaemonClient.ProxyInfo?)] {
        showAll ? nodes : Array(nodes.prefix(maxVisible))
    }

    var body: some View {
        VStack(spacing: 0) {
            // 网格
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(displayNodes, id: \.0) { nodeName, nodeInfo in
                    NodeChip(
                        name: nodeName,
                        isSelected: currentSelection == nodeName,
                        delay: delayResults[nodeName],
                        type: nodeInfo?.type ?? "",
                        onTap: { onSelectNode(nodeName) },
                        onLongPress: { onTestDelay(nodeName) })
                }
            }

            // 展开/收起按钮
            if nodes.count > maxVisible {
                Button(action: { withAnimation(.easeInOut(duration: 0.25)) { showAll.toggle() } }) {
                    HStack(spacing: 4) {
                        Image(systemName: showAll ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                        Text(showAll ? "收起" : "展开全部 (\(nodes.count))")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                }.buttonStyle(.plain)
            }
        }
    }
}

// MARK: 订阅页面（YAML 订阅链接列表）
struct SubscriptionsPage: View {
    @EnvironmentObject var client: DaemonClient

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("订阅 (0)").font(.subheadline).fontWeight(.semibold).foregroundStyle(WgTheme.accent)
                Spacer()
                Button(action: {}) {
                    Image(systemName: "plus.circle.fill").font(.system(size: 16)).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 20).padding(.vertical, 10)

            Divider().opacity(0.1)

            Spacer()
            VStack(spacing: 14) {
                Image(systemName: "link").font(.system(size: 44))
                    .foregroundStyle(.secondary.opacity(0.3))
                Text("暂无订阅").font(.subheadline).foregroundStyle(.secondary)
                Text("添加 YAML 订阅链接以自动更新节点").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }
}

// MARK: - 连接页面
struct ConnectionsPage: View {
    @EnvironmentObject var client: DaemonClient
    @State private var searchText = ""
    @State private var autoRefresh = true

    private func connStat(_ prefix: String, total: Int64, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(prefix).font(.caption).fontWeight(.bold).foregroundStyle(color)
            Text(formatBytes(total)).font(.caption).monospacedDigit().foregroundStyle(color)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1048576 { return "\(bytes / 1024) KB" }
        if bytes < 1073741824 { return String(format: "%.1f MB", Double(bytes) / 1024.0 / 1024.0) }
        return String(format: "%.2f GB", Double(bytes) / 1024.0 / 1024.0 / 1024.0)
    }

    private var filteredConnections: [DaemonClient.ConnectionInfo] {
        guard let conns = client.connections?.connections else { return [] }
        if searchText.isEmpty { return conns }
        return conns.filter {
            $0.metadata.host?.localizedCaseInsensitiveContains(searchText) ?? false ||
            $0.metadata.process?.localizedCaseInsensitiveContains(searchText) ?? false ||
            $0.metadata.destinationIP?.localizedCaseInsensitiveContains(searchText) ?? false ||
            $0.rule?.localizedCaseInsensitiveContains(searchText) ?? false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                TextField("搜索连接…", text: $searchText).textFieldStyle(.plain).font(.subheadline)
                Spacer()
            }.padding(.horizontal, 16).padding(.vertical, 8)

            Divider().opacity(0.1)

            if let conns = client.connections {
                HStack(spacing: 12) {
                    connStat("↑", total: conns.uploadTotal, color: .blue)
                    connStat("↓", total: conns.downloadTotal, color: .green)
                    Text("\(conns.connections.count) 条活跃").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive, action: {
                        Task { _ = await client.closeAllConnections() }
                    }, label: { Label("全部关闭", systemImage: "trash") }).controlSize(.small)
                }.padding(.horizontal, 16).padding(.vertical, 6)
            }

            if filteredConnections.isEmpty {
                Spacer(); VStack(spacing: 12) {
                    Image(systemName: "arrow.up.arrow.down.circle").font(.system(size: 40)).foregroundStyle(.secondary.opacity(0.25))
                    Text("暂无活跃连接").font(.subheadline).foregroundStyle(.secondary)
                }; Spacer()
            } else {
                List {
                    ForEach(filteredConnections) { conn in ConnectionRow(conn: conn)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive, action: { Task { _ = await client.closeConnection(id: conn.id) } }, label: { Label("关闭", systemImage: "xmark.circle.fill") })
                        }.listRowBackground(Color.clear)
                    }
                }.scrollContentBackground(.hidden).listStyle(.plain)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                await client.fetchConnections()
            }
        }
    }
}

struct ConnectionRow: View {
    let conn: DaemonClient.ConnectionInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let proc = conn.metadata.process, !proc.isEmpty {
                    Text(proc).font(.caption).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if let rule = conn.rule, !rule.isEmpty {
                    Text(rule).font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.06)).clipShape(Capsule())
                }
            }
            HStack(spacing: 8) {
                HStack(spacing: 3) {
                    Image(systemName: conn.metadata.netWork == "udp" ? "wifi.exclamationmark" : "arrow.right.circle")
                        .font(.caption2).foregroundStyle(conn.metadata.netWork == "udp" ? .orange : .blue)
                    if let host = conn.metadata.host, !host.isEmpty {
                        Text(host).font(.caption).lineLimit(1)
                    } else if let ip = conn.metadata.destinationIP, let port = conn.metadata.destinationPort {
                        Text("\(ip):\(port)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                HStack(spacing: 8) {
                    speedLabel("↑", conn.uploadSpeed, .blue)
                    speedLabel("↓", conn.downloadSpeed, .green)
                }
            }
        }.padding(.vertical, 6).padding(.horizontal, 4)
    }

    private func speedLabel(_ prefix: String, _ bps: Int64?, _ color: Color) -> some View {
        guard let s = bps, s > 0 else {
            return AnyView(Text(prefix + "--").font(.caption2).monospacedDigit().foregroundStyle(.tertiary))
        }
        return AnyView(Text(prefix + fmtBps(s)).font(.caption2).monospacedDigit().foregroundStyle(color))
    }

    private func fmtBps(_ bps: Int64) -> String {
        if bps < 1024 { return "\(bps)" }
        if bps < 1048576 { return "\(bps / 1024)K" }
        return String(format: "%.1fM", Double(bps) / 1048576.0)
    }
}

// MARK: 规则页面
struct RulesPage: View {
    @EnvironmentObject var client: DaemonClient
    @State private var searchText = ""

    private var filteredRules: [DaemonClient.RuleInfo] {
        if searchText.isEmpty { return client.rules }
        return client.rules.filter {
            $0.payload?.localizedCaseInsensitiveContains(searchText) ?? false ||
            $0.type.localizedCaseInsensitiveContains(searchText) ||
            $0.proxy?.localizedCaseInsensitiveContains(searchText) ?? false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
                TextField("搜索规则…", text: $searchText).textFieldStyle(.plain).font(.subheadline)
                Spacer()
                Text("\(filteredRules.count) 条").font(.caption).foregroundStyle(.tertiary)
            }.padding(.horizontal, 16).padding(.vertical, 10)

            Divider().opacity(0.1)

            if client.rules.isEmpty {
                Spacer(); VStack(spacing: 12) {
                    Image(systemName: "scroll.text.circles").font(.system(size: 40)).foregroundStyle(.secondary.opacity(0.25))
                    Text("无规则数据").font(.subheadline).foregroundStyle(.secondary)
                }; Spacer()
            } else {
                List {
                    ForEach(filteredRules) { rule in RuleRow(rule: rule).listRowBackground(Color.clear) }
                }.scrollContentBackground(.hidden).listStyle(.plain)
            }
        }
    }
}

struct RuleRow: View {
    let rule: DaemonClient.RuleInfo
    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(ruleColor(rule.type)).frame(width: 8, height: 8)
            Text(rule.payload ?? "").font(.caption).lineLimit(2).textSelection(.enabled)
            Spacer()
            if let proxy = rule.proxy, !proxy.isEmpty {
                Text(proxy).font(.caption2).fontWeight(.medium).foregroundStyle(proxyColor(proxy))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(proxyColor(proxy).opacity(0.08)).clipShape(Capsule())
            }
            if let size = rule.size, size > 0 {
                Text(fmtSize(size)).font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
            }
        }.padding(.vertical, 5).padding(.horizontal, 4)
    }

    private func ruleColor(_ type: String) -> Color {
        switch type {
        case "DOMAIN-SUFFIX","DOMAIN-KEYWORD","DOMAIN": return .blue
        case "IP-CIDR","IP-CIDR6","GEOIP": return .green
        case "GEOSITE": return .purple
        case "MATCH": return .orange
        case "PROCESS-NAME": return .cyan
        default: return .gray
        }
    }

    private func proxyColor(_ proxy: String) -> Color {
        let p = proxy.lowercased()
        if p.contains("direct") || p.contains("直连") { return .green }
        if p.contains("reject") || p.contains("拒绝") { return .red }
        if p.contains("proxy") || p.contains("代理") { return .blue }
        return .secondary
    }

    private func fmtSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        if bytes < 1048576 { return "\(bytes / 1024)KB" }
        return String(format: "%.1fMB", Double(bytes) / 1024.0 / 1024.0)
    }
}

// MARK: 日志页面（代理）
struct ProxyLogsPage: View {
    @EnvironmentObject var client: DaemonClient
    @State private var logLines: [String] = []
    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("实时日志").font(.subheadline).fontWeight(.medium)
                Spacer()
                Toggle("自动滚动", isOn: $autoScroll).toggleStyle(.switch).controlSize(.mini)
                Button("清除") { logLines.removeAll() }.font(.caption).buttonStyle(.borderless)
            }.padding(.horizontal, 16).padding(.vertical, 8)

            Divider().opacity(0.1)

            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(logLines.enumerated()), id: \.offset) { i, line in
                            Text(line).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(logColor(line)).textSelection(.enabled)
                                .padding(.horizontal, 8).padding(.vertical, 2).id(i)
                        }
                    }.padding(8)
                }
                .onChange(of: logLines.count) { _, newCount in
                    if autoScroll && newCount > 0 { withAnimation { scroll.scrollTo(newCount - 1, anchor: .bottom) } }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                await client.fetchLogs(n: 30)
                if !client.logLines.isEmpty { logLines = Array(client.logLines.suffix(50)) }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func logColor(_ line: String) -> Color {
        let l = line.lowercased()
        if l.contains("error") || l.contains("failed") { return .red }
        if l.contains("warn") { return .yellow }
        if l.contains("debug") { return .secondary }
        return .primary
    }
}

// MARK: 代理概览 Dashboard
struct ProxyDashboardPage: View {
    @EnvironmentObject var client: DaemonClient

    private var stats: (groups: Int, nodes: Int) {
        var g = 0; var n = Set<String>()
        for (_, p) in client.proxies {
            if ["Selector","URLTest","Fallback","LoadBalance","Smart"].contains(p.type) { g += 1; if let a = p.all { n.formUnion(a) } }
        }
        return (g, n.count)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WgTheme.spacing) {

                // 运行模式卡片
                HStack(spacing: 14) {
                    Image(systemName: modeIcon(client.mihomoConfig?.mode)).font(.system(size: 28))
                        .foregroundStyle(modeColor(client.mihomoConfig?.mode))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("运行模式").font(.caption).foregroundStyle(.secondary)
                        Text(client.mihomoConfig?.mode?.uppercased() ?? "未知")
                            .font(.title3).fontWeight(.bold)
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        modeBtn("Global", "globe.americas", client.mihomoConfig?.mode == "global")
                        modeBtn("Rule", "list.bullet.clipboard", client.mihomoConfig?.mode == "rule")
                        modeBtn("Direct", "arrow.forward.to.line", client.mihomoConfig?.mode == "direct")
                    }
                }.padding(18).background(WgTheme.cardBg)
                .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius).stroke(WgTheme.cardBorder, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: WgTheme.cardRadius))

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: WgTheme.spacing) {
                    dashCard(title: "策略组", value: "\(stats.groups)", icon: "list.bullet", color: .purple)
                    dashCard(title: "可用节点", value: "\(stats.nodes)", icon: "circle.grid.2x2", color: .blue)
                    dashCard(title: "活跃连接", value: "\(client.connections?.connections.count ?? 0)", icon: "arrow.up.arrow.down", color: .orange)
                }

                // 流量卡片
                if let conns = client.connections {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("实时流量").font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
                        HStack(spacing: 20) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("上传").font(.caption2).foregroundStyle(.blue)
                                Text(fmtBytes(conns.uploadTotal)).font(.title3.bold()).foregroundStyle(.blue)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("下载").font(.caption2).foregroundStyle(.green)
                                Text(fmtBytes(conns.downloadTotal)).font(.title3.bold()).foregroundStyle(.green)
                            }
                            Spacer()
                        }
                    }.padding(18).background(WgTheme.cardBg)
                    .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius).stroke(WgTheme.cardBorder, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: WgTheme.cardRadius))
                }

                // 版本信息
                HStack(spacing: 14) {
                    Image(systemName: "info.circle").font(.system(size: 22)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mihomo 核心").font(.caption).foregroundStyle(.secondary)
                        Text(client.mihomoVersion?.version ?? "未知版本").font(.body).fontWeight(.medium)
                        if let v = client.mihomoVersion {
                            HStack(spacing: 8) {
                                tag(v.meta ? "Meta" : nil, .purple)
                                tag(v.premium ? "Premium" : nil, .orange)
                                tag(!v.meta && !v.premium ? "Core" : nil, .blue)
                            }
                        }
                    }
                    Spacer()
                    Text(client.proxyAddress).font(.caption).foregroundStyle(.tertiary)
                }.padding(18).background(WgTheme.cardBg)
                .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius).stroke(WgTheme.cardBorder, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: WgTheme.cardRadius))

                Spacer(minLength: 0)
            }.padding(28)
        }
    }

    private func modeIcon(_ mode: String?) -> String {
        switch mode { case "global": return "globe.americas"; case "rule": return "list.bullet.clipboard"; case "direct": return "arrow.forward.to.line"; default: return "questionmark.circle" }
    }

    private func modeColor(_ mode: String?) -> Color {
        switch mode { case "global": return .red; case "rule": return .blue; case "direct": return .green; default: return .gray }
    }

    private func modeBtn(_ label: String, _ icon: String, _ active: Bool) -> some View {
        Button {} label: {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 9))
                Text(label).font(.caption2).fontWeight(active ? .semibold : .regular)
            }.foregroundStyle(active ? .white : .secondary)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(active ? modeColor(client.mihomoConfig?.mode) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain)
    }

    private func dashCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(color)
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 26, weight: .bold, design: .rounded)).foregroundStyle(color)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
        .background(WgTheme.cardBg)
        .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius).stroke(WgTheme.cardBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: WgTheme.cardRadius))
    }

    private func tag(_ text: String?, _ color: Color) -> some View {
        Group {
            if let t = text {
                Text(t).font(.caption2).fontWeight(.medium).foregroundStyle(color)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(color.opacity(0.1)).clipShape(Capsule())
            }
        }
    }

    private func fmtBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1048576 { return "\(bytes / 1024) KB" }
        if bytes < 1073741824 { return String(format: "%.1f MB", Double(bytes) / 1024.0 / 1024.0) }
        return String(format: "%.2f GB", Double(bytes) / 1024.0 / 1024.0 / 1024.0)
    }
}
