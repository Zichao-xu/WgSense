import SwiftUI

// 代理页（AnGe「代理」一比一功能）：控制栏 + 策略/域名/节点/订阅 四个子视图。

struct PPProxiesPage: View {
    @ObservedObject private var store = ProxyPanelStore.shared
    @ObservedObject private var backends = MihomoBackendStore.shared

    var body: some View {
        VStack(spacing: 0) {
            PPToolbar()
                .padding(.bottom, 14)
            content
        }
        .environmentObject(store)
        .overlay(alignment: .bottomTrailing) { PPNoticeStack().environmentObject(store) }
        .onAppear { store.activate() }
        .onDisappear { store.deactivate() }
        .onChange(of: backends.activeID) { _, _ in store.backendChanged() }
    }

    @ViewBuilder
    private var content: some View {
        if backends.active == nil {
            PPEmptyState(symbol: "server.rack", title: "还没有后端", detail: "在代理设置中添加 Clash / Mihomo 控制器")
        } else if let error = store.lastError, store.proxyMap.isEmpty {
            PPEmptyState(symbol: "exclamationmark.triangle.fill", title: "无法连接后端", detail: error)
        } else if store.proxyMap.isEmpty {
            ProgressView().frame(maxWidth: .infinity, minHeight: 240)
        } else {
            switch store.tab {
            case .policy: PPGroupList(groups: store.policyGroups)
            case .node: PPNodeGroupList()
            case .provider: PPProviderList()
            case .domain:
                PPDomainGroupView().padding(.bottom, 20)
            }
        }
    }
}

// MARK: - 控制栏（P-C01…P-C07）

private struct PPToolbar: View {
    @EnvironmentObject private var store: ProxyPanelStore
    @State private var showSettings = false
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var tabIndicator

    var body: some View {
        HStack(spacing: 10) {
            tabs
            if store.tab == .policy, let config = store.config {
                Picker("模式", selection: Binding(
                    get: { config.mode },
                    set: { mode in Task { await store.setMode(mode) } }
                )) {
                    ForEach(modes(config), id: \.self) { mode in
                        Text(modeTitle(mode)).tag(mode)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            searchField
            Spacer(minLength: 0)
            if store.tab == .provider {
                Button { Task { await store.updateAllProviders() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .symbolEffect(.rotate, isActive: store.isTesting("updateAll"))
                }
                .buttonStyle(WgToolbarIconButtonStyle())
                .help("全部更新")
            }
            Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(WgToolbarIconButtonStyle())
                .help("代理设置")
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    PPSettingsPopover().environmentObject(store)
                }
            Button { toggleCollapseAll() } label: {
                Image(systemName: hasExpanded ? "chevron.up.2" : "chevron.down.2")
            }
            .buttonStyle(WgToolbarIconButtonStyle())
            .help(hasExpanded ? "全部折叠" : "全部展开")
            Button { Task { await store.testAll() } } label: {
                if store.isTesting("all") {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "bolt.fill")
                }
            }
            .buttonStyle(WgToolbarIconButtonStyle())
            .help("全部测速")
        }
        .focusEffectDisabled()
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(PPTab.allCases) { tab in
                Button { withAnimation(WgDesign.spring) { store.tab = tab } } label: {
                    HStack(spacing: 4) {
                        Text(tab.title)
                        if tab != .domain {
                            Text("\(store.count(for: tab))")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .font(.system(size: 12, weight: store.tab == tab ? .semibold : .regular))
                    .padding(.horizontal, 11)
                    .frame(height: 26)
                    .background {
                        if store.tab == tab {
                            Capsule()
                                .fill((colorScheme == .dark ? Color.white : Color.black).opacity(0.10))
                                .matchedGeometryEffect(id: "ppTab", in: tabIndicator)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .wgInteractiveSurface(cornerRadius: 16)
        .fixedSize()
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("搜索 · 多个关键词用空格分隔", text: $store.filter)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !store.filter.isEmpty {
                Button { store.filter = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .frame(minWidth: 120, maxWidth: 280)
        .wgInteractiveSurface(cornerRadius: 14)
    }

    private func modes(_ config: MihomoRuntimeConfig) -> [String] {
        let list = config.modeList ?? []
        return list.isEmpty ? ["rule", "global", "direct"] : list
    }

    private func modeTitle(_ mode: String) -> LocalizedStringKey {
        switch mode.lowercased() {
        case "rule": return "规则"
        case "global": return "全局"
        case "direct": return "直连"
        default: return LocalizedStringKey(mode)
        }
    }

    private var targets: [String] {
        switch store.tab {
        case .policy: return store.policyGroups
        case .node: return store.nodeGroups
        case .provider: return store.providers.map { "provider:" + $0.name }
        case .domain: return []
        }
    }

    private var hasExpanded: Bool { targets.contains { store.collapseMap[$0] == true } }

    private func toggleCollapseAll() {
        let expand = !hasExpanded
        var map = store.collapseMap
        targets.forEach { map[$0] = expand }
        withAnimation(WgDesign.spring) { store.collapseMap = map }
    }
}

// MARK: - 策略组列表（P-G15 自动双列）

private struct PPGroupList: View {
    @EnvironmentObject private var store: ProxyPanelStore
    var groups: [String]

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                let twoColumns = geo.size.width >= 760 && groups.count > 1
                Group {
                    if twoColumns {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(0..<2, id: \.self) { column in
                                LazyVStack(spacing: 12) {
                                    ForEach(Array(groups.enumerated()).filter { $0.offset % 2 == column }.map(\.element), id: \.self) { name in
                                        PPGroupCard(name: name)
                                    }
                                }
                            }
                        }
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(groups, id: \.self) { PPGroupCard(name: $0) }
                        }
                    }
                }
                .padding(.bottom, 20)
            }
        }
    }
}

private struct PPNodeGroupList: View {
    @EnvironmentObject private var store: ProxyPanelStore

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(store.nodeGroupBlocks, id: \.self) { block in
                    VStack(spacing: 0) {
                        ForEach(Array(block.enumerated()), id: \.element) { index, name in
                            if index > 0 { Divider().padding(.horizontal, 16) }
                            PPGroupCard(name: name, chromeless: true)
                        }
                    }
                    .wgInteractiveSurface(cornerRadius: WgDesign.cardRadius)
                }
            }
            .padding(.bottom, 20)
        }
    }
}

// MARK: - 策略组卡片（P-G01…P-G16）

struct PPGroupCard: View {
    @EnvironmentObject private var store: ProxyPanelStore
    var name: String
    /// 内嵌在策略穿透里的层级卡片（没有外框、没有穿透区）。
    var embedded = false
    var level = 0
    var rootGroup: String?
    /// 在节点组块里时由外层提供外框。
    var chromeless = false
    var onSelect: ((String, String) -> Void)?

    @State private var showPenetration = false

    private var collapseKey: String { embedded ? "penetration:\(rootGroup ?? ""):level-\(level)" : name }
    private var expanded: Bool { store.collapseMap[collapseKey] == true }

    var body: some View {
        if let group = store.proxyMap[name] {
            let rendered = store.renderProxies(of: name)
            VStack(alignment: .leading, spacing: 10) {
                header(group)
                if expanded {
                    Group {
                        if store.groupProxiesByProvider {
                            PPProviderSectionsView(group: name, names: rendered, previewOnly: false) { select($0) }
                        } else {
                            PPNodeGrid(group: name, names: rendered)
                        }
                    }
                    .transition(.opacity)
                    if !embedded { PPPenetrationSection(root: name) }
                } else if store.groupProxiesByProvider {
                    PPProviderSectionsView(group: name, names: rendered, previewOnly: true) { select($0) }
                } else {
                    PPPreview(nodes: rendered, now: group.now, group: name) { node in select(node) }
                }
            }
            .padding(embedded ? 0 : 16)
            .padding(.vertical, embedded ? 10 : 0)
            .modifier(CardChrome(enabled: !embedded && !chromeless))
            .contentShape(Rectangle())
            .onRightClick { Task { await store.testGroup(name) } }
            .animation(WgDesign.spring, value: expanded)
        }
    }

    private func header(_ group: MihomoProxy) -> some View {
        let large = store.useLargeProxyGroupIcon && group.icon != nil
        return HStack(alignment: large ? .top : .center, spacing: 10) {
            if large {
                PPGroupIcon(icon: group.icon, size: max(store.proxyGroupIconSize, 46))
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if !large, group.icon != nil {
                        PPGroupIcon(icon: group.icon, size: store.proxyGroupIconSize)
                            .padding(.trailing, store.proxyGroupIconMargin - 6)
                    }
                    Text(verbatim: name)
                        .font(.system(size: embedded ? 13 : 14, weight: .semibold))
                        .lineLimit(1)
                    if !embedded {
                        Button("域名穿透") { showPenetration = true }
                            .buttonStyle(WgPillButtonStyle())
                            .font(.system(size: 11, weight: .medium))
                            .sheet(isPresented: $showPenetration) { PPRulePenetrationSheet(group: name) }
                    }
                    Text(verbatim: embedded ? "\(group.type) (\(store.availabilityText(of: name)))" : group.type)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if store.manageHiddenGroup {
                        Button {
                            store.hiddenGroupMap[name] = !store.isHidden(name)
                        } label: {
                            Image(systemName: store.isHidden(name) ? "eye.slash" : "eye")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(WgToolbarIconButtonStyle())
                        .help(store.isHidden(name) ? "显示此组" : "隐藏此组")
                    }
                    Spacer(minLength: 6)
                    PPLatencyTag(name: group.now, group: name, loading: store.isTesting("group:\(name)")) {
                        Task { await store.testGroup(name) }
                    }
                }
                HStack(spacing: 8) {
                    PPRouteView(group: name)
                    PPGroupSpeed(group: name)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(WgDesign.spring) { store.collapseMap[collapseKey] = !expanded }
        }
    }

    private func select(_ node: String) {
        onSelect?(name, node)
        Task { await store.select(group: name, node: node) }
    }
}

private struct CardChrome: ViewModifier {
    var enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.wgInteractiveSurface(cornerRadius: WgDesign.cardRadius)
        } else {
            content
        }
    }
}

// MARK: - 策略穿透（P-P01…P-P04）

private struct PPPenetrationSection: View {
    @EnvironmentObject private var store: ProxyPanelStore
    var root: String

    @State private var isExpanded = false
    @State private var selectedMap: [String: String] = [:]
    @State private var lastSelectedGroup = ""
    @State private var stepwiseVisible = 1

    private var mode: PPPenetrationMode {
        PPPenetrationMode(rawValue: store.penetrationModeMap[root] ?? "") ?? .stepwise
    }

    /// 沿（用户在穿透层里的选择 ?? 当前实际选择）向下的组链，防环。
    private var penetrated: [String] {
        var names: [String] = []
        var visited: Set<String> = [root]
        var current = root
        while true {
            let selected: String? = {
                guard let s = selectedMap[current],
                      (store.proxyMap[current]?.all ?? []).contains(s),
                      store.isGroup(s) else { return nil }
                return s
            }()
            let actual = store.groupChain(current).dropFirst().first
            guard let next = selected ?? actual, !visited.contains(next) else { break }
            names.append(next)
            visited.insert(next)
            current = next
        }
        return names
    }

    var body: some View {
        let groups = penetrated
        let canPenetrate = !groups.isEmpty
        let canSwitch = groups.count > 1
        let rendered = !canPenetrate ? [] : (mode == .stepwise ? Array(groups.prefix(stepwiseVisible)) : groups)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    guard canPenetrate else { return }
                    withAnimation(WgDesign.spring) {
                        if !isExpanded, mode == .stepwise { stepwiseVisible = 1 }
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(isExpanded ? "收起穿透" : "策略穿透")
                        Image(systemName: "chevron.down")
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(WgPillButtonStyle())
                .disabled(!canPenetrate)
                Spacer()
                Picker("", selection: Binding(
                    get: { mode },
                    set: { newMode in
                        store.penetrationModeMap[root] = newMode.rawValue
                        lastSelectedGroup = ""
                        if newMode == .stepwise { stepwiseVisible = 1 }
                    }
                )) {
                    Text("逐层穿透").tag(PPPenetrationMode.stepwise)
                    Text("穿透到底").tag(PPPenetrationMode.full)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .disabled(!canPenetrate || !canSwitch)
            }
            if isExpanded && !rendered.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(rendered.enumerated()), id: \.element) { index, name in
                        Divider()
                        PPGroupCard(name: name, embedded: true, level: index + 1, rootGroup: root) { group, node in
                            handleSelection(group: group, node: node)
                        }
                    }
                }
                .padding(.top, 8)
                .transition(.opacity)
            }
        }
        .padding(.top, 4)
        .onChange(of: canPenetrate) { _, value in
            if !value {
                isExpanded = false
                lastSelectedGroup = ""
                selectedMap = [:]
                stepwiseVisible = 1
            }
        }
        .onChange(of: canSwitch) { _, value in
            if !value { store.penetrationModeMap[root] = PPPenetrationMode.stepwise.rawValue }
        }
    }

    /// P-P04：某层改选后清掉下游已选，再按逐层模式推进可见层数。
    private func handleSelection(group: String, node: String) {
        lastSelectedGroup = group
        var map = selectedMap
        store.descendantGroups(group).forEach { map.removeValue(forKey: $0) }
        if (store.proxyMap[group]?.all ?? []).contains(node), store.isGroup(node) {
            map[group] = node
        } else {
            map.removeValue(forKey: group)
        }
        selectedMap = map
        if mode == .stepwise {
            let names = penetrated
            let index = names.firstIndex(of: lastSelectedGroup) ?? -1
            stepwiseVisible = index == -1 ? 1 : min(names.count, index + 2)
        }
    }
}

// MARK: - 订阅（P-V01…P-V05）

private struct PPProviderList: View {
    @EnvironmentObject private var store: ProxyPanelStore

    var body: some View {
        if store.providers.isEmpty {
            PPEmptyState(symbol: "tray", title: "没有订阅",
                         detail: "当前配置里没有 http/file 类型的代理提供商（Compatible 与 default 不在此列出）")
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(store.providers) { PPProviderCard(provider: $0) }
                }
                .padding(.bottom, 20)
            }
        }
    }
}

private struct PPProviderCard: View {
    @EnvironmentObject private var store: ProxyPanelStore
    var provider: MihomoProxyProvider

    private var key: String { "provider:" + provider.name }
    private var expanded: Bool { store.collapseMap[key] == true }

    var body: some View {
        let names = provider.proxies.map(\.name)
        let alive = names.filter { store.latency($0, group: provider.name) != mihomoNotConnected }.count
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(verbatim: provider.name).font(.system(size: 14, weight: .semibold))
                Text(verbatim: "(\(alive)/\(names.count))").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await store.healthCheckProvider(provider.name) } } label: {
                    if store.isTesting("health:\(provider.name)") { ProgressView().controlSize(.small) }
                    else { Image(systemName: "bolt.fill") }
                }
                .buttonStyle(WgToolbarIconButtonStyle())
                .help("健康检查")
                if provider.vehicleType != "Inline" {
                    Button { Task { await store.updateProvider(provider.name) } } label: {
                        Image(systemName: "arrow.clockwise")
                            .symbolEffect(.rotate, isActive: store.isTesting("update:\(provider.name)"))
                    }
                    .buttonStyle(WgToolbarIconButtonStyle())
                    .help("更新")
                }
            }
            HStack(spacing: 14) {
                if let info = provider.subscriptionInfo {
                    Label(expireText(info), systemImage: "calendar")
                    Label(usageText(info), systemImage: "chart.bar.fill")
                }
                if let updated = provider.updatedAt.flatMap(PPPersist.parseDate) {
                    Label {
                        Text("更新于 ") + Text(updated, style: .relative)
                    } icon: { Image(systemName: "clock") }
                }
                Spacer()
                if store.categoryFeatureEnabled {
                    PPCategoryControls(provider: provider.name)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            if expanded {
                if store.categoryActive(provider: provider.name) {
                    PPCategorySections(provider: provider.name, names: names)
                } else {
                    PPNodeGrid(group: provider.name, names: names)
                }
            } else {
                PPPreview(nodes: names, now: nil, group: provider.name) { _ in }
            }
        }
        .padding(16)
        .wgInteractiveSurface(cornerRadius: WgDesign.cardRadius) {
            withAnimation(WgDesign.spring) { store.collapseMap[key] = !expanded }
        }
    }

    private func expireText(_ info: MihomoSubscriptionInfo) -> String {
        guard info.expire > 0 else { return "不限时" }
        let date = Date(timeIntervalSince1970: TimeInterval(info.expire))
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "到期时间 \(f.string(from: date))"
    }

    private func usageText(_ info: MihomoSubscriptionInfo) -> String {
        let used = info.upload + info.download
        let fmt = ByteCountFormatter()
        guard info.total > 0 else { return "已使用 \(fmt.string(fromByteCount: used))" }
        return "\(fmt.string(fromByteCount: used)) / \(fmt.string(fromByteCount: info.total))"
    }
}

// MARK: - 代理设置（P-C07）

private struct PPSettingsPopover: View {
    @EnvironmentObject private var store: ProxyPanelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("代理设置")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            Divider()
            VStack(spacing: 0) {
                row("排序方式") {
                    Picker("", selection: Binding(get: { store.sortType }, set: { store.sortType = $0 })) {
                        ForEach(PPSortType.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                if !store.smartWeights.isEmpty {
                    toggle("Smart 组根据使用频率排序", $store.useSmartGroupSort)
                }
                toggle("节点根据提供商分组", $store.groupProxiesByProvider)
                toggle("隐藏不可用节点", $store.hideUnavailableProxies)
                toggle("管理隐藏代理组", $store.manageHiddenGroup)
                toggle("切换节点时自动断开连接", $store.automaticDisconnection)
                toggle("显示完整路由节点", $store.displayFinalOutbound)
                row("节点卡片最小宽度") {
                    HStack(spacing: 6) {
                        TextField("", value: $store.minProxyCardWidth, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 60)
                        Button("重置") { store.minProxyCardWidth = store.smallCard ? 140 : 180 }
                            .buttonStyle(WgPillButtonStyle())
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 320)
        .focusEffectDisabled()
    }

    private func toggle(_ title: LocalizedStringKey, _ binding: Binding<Bool>) -> some View {
        row(title) {
            Toggle("", isOn: binding).toggleStyle(.switch).controlSize(.small).labelsHidden()
        }
    }

    private func row<A: View>(_ title: LocalizedStringKey, @ViewBuilder _ accessory: () -> A) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            accessory()
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 34)
    }
}

// MARK: - 通知（P-T01…P-T03）

private struct PPNoticeStack: View {
    @EnvironmentObject private var store: ProxyPanelStore

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(store.notices) { notice in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: symbol(notice.kind))
                        .foregroundStyle(tint(notice.kind))
                        .font(.system(size: 14))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: notice.title)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(2)
                        Text(verbatim: notice.detail)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Button { store.dismiss(notice.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
                .padding(12)
                .frame(width: 260, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(16)
        .animation(WgDesign.spring, value: store.notices)
    }

    private func symbol(_ kind: PPNotice.Kind) -> String {
        switch kind {
        case .info: return "bolt.horizontal.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func tint(_ kind: PPNotice.Kind) -> Color {
        switch kind {
        case .info: return .accentColor
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

private struct PPEmptyState: View {
    var symbol: String
    var title: LocalizedStringKey
    var detail: String

    var body: some View {
        VStack(spacing: 10) {
            WgSquareBadge(symbol: symbol, tint: .gray, size: 40, dimmed: true)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(verbatim: detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
        .wgInteractiveSurface(cornerRadius: WgDesign.cardRadius)
    }
}
