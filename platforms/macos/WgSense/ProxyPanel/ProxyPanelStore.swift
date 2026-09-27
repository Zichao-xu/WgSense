import Foundation
import SwiftUI

// 代理面板的数据与逻辑层。一比一对应 AnGe-ClashBoard：
//   store/proxies.ts（拉取、测速、选择、链路）· composables/proxies.ts（组划分、隐藏、GLOBAL）
//   composables/renderProxies.ts（排序过滤）· store/smart.ts（Smart 权重）
// 编号对照 docs/proxy-panel-parity.md。

enum PPTab: String, CaseIterable, Identifiable {
    case policy, domain, node, provider
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .policy: return "策略"
        case .domain: return "域名"
        case .node: return "节点"
        case .provider: return "订阅"
        }
    }
}

enum PPSortType: String, CaseIterable, Identifiable {
    case defaultsort, nameasc, namedesc, latencyasc, latencydesc
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .defaultsort: return "按配置排序"
        case .nameasc: return "按名称升序"
        case .namedesc: return "按名称降序"
        case .latencyasc: return "按延迟升序"
        case .latencydesc: return "按延迟降序"
        }
    }
}

enum PPPreviewType: String, CaseIterable, Identifiable {
    case auto, dots, bar
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .auto: return "自动"
        case .dots: return "点"
        case .bar: return "条"
        }
    }
}

enum PPPenetrationMode: String { case stepwise, full }

/// 进度型通知（原版 showNotification 同 key 原地更新）。
struct PPNotice: Identifiable, Equatable {
    enum Kind { case info, success, warning, error }
    var id: String
    var title: String
    var detail: String
    var kind: Kind
}

@MainActor
final class ProxyPanelStore: ObservableObject {
    static let shared = ProxyPanelStore()

    static let testURLDefault = "https://www.gstatic.com/generate_204"
    static let ipv6TestURL = "https://ipv6.google.com/generate_204"
    static let global = "GLOBAL"

    // MARK: 数据（P-D01…）

    @Published private(set) var proxyMap: [String: MihomoProxy] = [:]
    @Published private(set) var proxyGroupList: [String] = []
    @Published private(set) var providers: [MihomoProxyProvider] = []
    @Published private(set) var config: MihomoRuntimeConfig?
    @Published private(set) var version: MihomoVersionInfo?
    @Published private(set) var lastError: String?
    @Published private(set) var smartWeights: [String: [String: String]] = [:]
    @Published private(set) var smartOrder: [String: [String: Int]] = [:]
    /// 本地补记的测速历史（逐节点测速结果，原版 setHistory）。
    @Published private(set) var localHistory: [String: [MihomoDelayHistory]] = [:]
    @Published var ipv6Map: [String: Bool] = PPPersist.dict("ipv6Map")

    /// 组 → 当前经过该组的下载速度（来自连接推送，P-G08）。
    @Published private(set) var groupDownloadSpeed: [String: Int64] = [:]
    private var activeConnections: [MihomoConnection] = []
    private var lastConnectionBytes: [String: Int64] = [:]
    private var lastConnectionTime: Date?

    @Published private(set) var testingKeys: Set<String> = []
    @Published private(set) var notices: [PPNotice] = []

    // MARK: 界面状态

    @Published var tab: PPTab = PPTab(rawValue: UserDefaults.standard.string(forKey: "pp.tab") ?? "") ?? .policy {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: "pp.tab") }
    }
    @Published var filter = ""
    @Published var collapseMap: [String: Bool] = PPPersist.dict("collapseGroupMap") {
        didSet { PPPersist.save(collapseMap, "collapseGroupMap") }
    }
    @Published var hiddenGroupMap: [String: Bool] = PPPersist.dict("hiddenGroupMap") {
        didSet { PPPersist.save(hiddenGroupMap, "hiddenGroupMap") }
    }
    @Published var penetrationModeMap: [String: String] = PPPersist.dict("penetrationModeMap") {
        didSet { PPPersist.save(penetrationModeMap, "penetrationModeMap") }
    }

    // MARK: 设置（默认值与原版一致）

    @AppStorage("pp.sortType") var sortTypeRaw = PPSortType.defaultsort.rawValue
    @AppStorage("pp.useSmartGroupSort") var useSmartGroupSort = false
    @AppStorage("pp.groupProxiesByProvider") var groupProxiesByProvider = false
    @AppStorage("pp.hideUnavailableProxies") var hideUnavailableProxies = false
    @AppStorage("pp.manageHiddenGroup") var manageHiddenGroup = false
    @AppStorage("pp.automaticDisconnection") var automaticDisconnection = true
    @AppStorage("pp.displayFinalOutbound") var displayFinalOutbound = false
    @AppStorage("pp.minProxyCardWidth") var minProxyCardWidth = 180.0
    @AppStorage("pp.speedtestUrl") var speedtestUrl = ProxyPanelStore.testURLDefault
    @AppStorage("pp.speedtestTimeout") var speedtestTimeout = 5000
    @AppStorage("pp.independentLatencyTest") var independentLatencyTest = false
    @AppStorage("pp.ipv6Test") var ipv6Test = false
    @AppStorage("pp.lowLatency") var lowLatency = 400
    @AppStorage("pp.mediumLatency") var mediumLatency = 800
    @AppStorage("pp.previewType") var previewTypeRaw = PPPreviewType.auto.rawValue
    @AppStorage("pp.smallCard") var smallCard = false
    @AppStorage("pp.truncateProxyName") var truncateProxyName = true
    @AppStorage("pp.largeGroupIcon") var useLargeProxyGroupIcon = false
    @AppStorage("pp.groupIconSize") var proxyGroupIconSize = 24.0
    @AppStorage("pp.groupIconMargin") var proxyGroupIconMargin = 6.0
    @AppStorage("pp.displayGlobalByMode") var displayGlobalByMode = false
    @AppStorage("pp.groupTestUrls") var groupTestUrlsRaw = "{}"

    var sortType: PPSortType {
        get { PPSortType(rawValue: sortTypeRaw) ?? .defaultsort }
        set { sortTypeRaw = newValue.rawValue; objectWillChange.send() }
    }
    var previewType: PPPreviewType {
        get { PPPreviewType(rawValue: previewTypeRaw) ?? .auto }
        set { previewTypeRaw = newValue.rawValue; objectWillChange.send() }
    }
    var groupTestUrls: [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(groupTestUrlsRaw.utf8))) ?? [:]
    }

    private var fetchGeneration = 0
    private var connectionTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?

    private init() {}

    // MARK: 后端

    private var api: MihomoAPI? {
        let store = MihomoBackendStore.shared
        guard let backend = store.active else { return nil }
        return MihomoAPI(backend: backend, secret: store.secret(for: backend))
    }

    /// 代理页出现时调用：拉数据 + 开连接推送。
    func activate() {
        Task { await fetchAll() }
        startConnectionStream()
    }

    /// 代理页离开时调用：停掉推送与自动刷新，不在后台消耗。
    func deactivate() {
        connectionTask?.cancel()
        connectionTask = nil
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    func backendChanged() {
        proxyMap = [:]
        proxyGroupList = []
        providers = []
        config = nil
        smartWeights = [:]
        smartOrder = [:]
        connectionTask?.cancel()
        activate()
    }

    func fetchAll() async {
        guard let api else { lastError = "未配置后端"; return }
        async let cfg = try? api.config()
        async let ver = try? api.version()
        await fetchProxies()
        if let c = await cfg, config != c { config = c }
        if let v = await ver, version != v { version = v }
    }

    // MARK: 拉取（P-D01…P-D05）

    func fetchProxies() async {
        guard let api else { return }
        fetchGeneration += 1
        let generation = fetchGeneration
        do {
            async let proxiesReq = api.proxies()
            async let providersReq = api.providers()
            let (proxyData, providerData) = try await (proxiesReq, providersReq)
            // P-D03：后发的请求已返回时，丢弃这次旧结果。
            guard generation == fetchGeneration else { return }

            let sortIndex: [String] = proxyData.proxies[Self.global]?.all ?? []
            let validProviders: [MihomoProxyProvider] = providerData.providers.values
                .filter { $0.name != "default" && $0.vehicleType != "Compatible" }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

            var merged: [String: MihomoProxy] = [:]
            for provider in validProviders {
                for var proxy in provider.proxies {
                    if proxy.providerName == nil { proxy.providerName = provider.name }
                    merged[proxy.name] = proxy
                }
            }
            for (name, proxy) in proxyData.proxies {
                if var base = merged[name] {
                    // 控制器数据覆盖提供商数据，但保留提供商名。
                    let providerName = base.providerName
                    base = proxy
                    if base.providerName == nil { base.providerName = providerName }
                    merged[name] = base
                } else {
                    merged[name] = proxy
                }
            }

            let groups: [String] = proxyData.proxies.values
                .filter { $0.isGroup && $0.name != Self.global }
                .map(\.name)
                .sorted { a, b in
                    let ia = sortIndex.firstIndex(of: a) ?? Int.max
                    let ib = sortIndex.firstIndex(of: b) ?? Int.max
                    return ia < ib
                }

            if ipv6Test {
                var map = ipv6Map
                for (name, proxy) in merged where proxy.extra[Self.ipv6TestURL]?.last.map({ $0.delay > mihomoNotConnected }) == true {
                    map[name] = true
                }
                if map != ipv6Map { ipv6Map = map; PPPersist.save(map, "ipv6Map") }
            }

            // 合并远端历史后，本地补记的历史里已被远端覆盖的部分丢弃。
            localHistory = localHistory.filter { name, _ in merged[name]?.history.isEmpty ?? true }

            if proxyMap != merged { proxyMap = merged }
            if proxyGroupList != groups { proxyGroupList = groups }
            if providers != validProviders { providers = validProviders }
            if lastError != nil { lastError = nil }

            if merged.values.contains(where: { $0.type.lowercased() == "smart" }) {
                await fetchSmartWeights()
            }
            scheduleAutoRefresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func fetchSmartWeights() async {
        guard let api, let response = try? await api.smartWeights() else { return }
        var weights: [String: [String: String]] = [:]
        var order: [String: [String: Int]] = [:]
        for (group, ranks) in response.weights {
            guard let ranks, !ranks.isEmpty else { continue }
            weights[group] = Dictionary(ranks.map { ($0.name, $0.rank) }, uniquingKeysWith: { a, _ in a })
            order[group] = Dictionary(ranks.enumerated().map { ($1.name, $0) }, uniquingKeysWith: { a, _ in a })
        }
        if smartWeights != weights { smartWeights = weights }
        if smartOrder != order { smartOrder = order }
    }

    // MARK: 组划分（P-D06…P-D09）

    func isGroup(_ name: String) -> Bool { proxyMap[name]?.isGroup ?? false }

    /// 原版 helper/isProxyGroup：除真正的组外，DIRECT/REJECT/PASS/DNS/Compatible 等内置出口也算“组”。
    /// 组划分（P-D06）和“子组排在节点前”（P-S01）都依赖这个口径。
    private static let groupLikeTypes: Set<String> = [
        "dns", "compatible", "direct", "reject", "rejectdrop", "pass",
        "fallback", "urltest", "loadbalance", "selector", "smart",
    ]

    func isProxyGroupLike(_ name: String) -> Bool {
        guard let proxy = proxyMap[name] else { return false }
        return proxy.isGroup || Self.groupLikeTypes.contains(proxy.type.lowercased())
    }

    func isHidden(_ name: String) -> Bool {
        hiddenGroupMap[name] ?? proxyMap[name]?.hidden ?? false
    }

    private func filterHidden(_ names: [String]) -> [String] {
        manageHiddenGroup ? names : names.filter { !isHidden($0) }
    }

    /// P-D08：根据模式显示 GLOBAL。
    var currentGroups: [String] {
        if displayGlobalByMode {
            if config?.mode.uppercased() == Self.global { return [Self.global] }
            return filterHidden(proxyGroupList)
        }
        return filterHidden(proxyGroupList + (proxyMap[Self.global] != nil ? [Self.global] : []))
    }

    /// P-D06：成员全是节点（或全是节点组）的组 = 节点组。递归判定，防环。
    var nodeGroupNames: Set<String> {
        var resolved: [String: Bool] = [:]
        var visiting: Set<String> = []
        func isNodeGroup(_ name: String) -> Bool {
            if let cached = resolved[name] { return cached }
            guard let proxy = proxyMap[name], let all = proxy.all, !all.isEmpty, !visiting.contains(name) else {
                resolved[name] = false
                return false
            }
            visiting.insert(name)
            let result = all.allSatisfy { member in
                guard proxyMap[member] != nil else { return false }
                return isProxyGroupLike(member) ? isNodeGroup(member) : true
            }
            visiting.remove(name)
            resolved[name] = result
            return result
        }
        return Set(currentGroups.filter { isNodeGroup($0) })
    }

    var policyGroups: [String] {
        let nodes = nodeGroupNames
        return currentGroups.filter { !nodes.contains($0) }
    }

    var nodeGroups: [String] {
        let nodes = nodeGroupNames
        return currentGroups.filter { nodes.contains($0) }
    }

    /// P-D07：节点组按引用关系打包。
    var nodeGroupBlocks: [[String]] {
        let groups = nodeGroups
        let groupSet = Set(groups)
        func children(_ name: String) -> [String] { (proxyMap[name]?.all ?? []).filter { groupSet.contains($0) } }
        var referenced: Set<String> = []
        groups.forEach { children($0).forEach { referenced.insert($0) } }
        var assigned: Set<String> = []
        var blocks: [[String]] = []
        func appendBlock(_ root: String) {
            guard !assigned.contains(root), groupSet.contains(root) else { return }
            var block: [String] = []
            var visited: Set<String> = []
            func walk(_ name: String) {
                guard !visited.contains(name), !assigned.contains(name), groupSet.contains(name) else { return }
                visited.insert(name)
                assigned.insert(name)
                block.append(name)
                children(name).forEach(walk)
            }
            walk(root)
            if !block.isEmpty { blocks.append(block) }
        }
        groups.filter { !referenced.contains($0) }.forEach(appendBlock)
        groups.forEach(appendBlock)
        return blocks
    }

    func count(for tab: PPTab) -> Int {
        switch tab {
        case .policy: return policyGroups.count
        case .domain: return 0
        case .node: return nodeGroups.count
        case .provider: return providers.count
        }
    }

    // MARK: 延迟（P-D10）

    func testURL(for group: String?) -> String {
        let fallback = speedtestUrl.isEmpty ? Self.testURLDefault : speedtestUrl
        guard let group, independentLatencyTest else { return fallback }
        if let url = groupTestUrls[group], !url.isEmpty { return url }
        return proxyMap[group]?.testUrl ?? providers.first { $0.name == group }?.testUrl ?? fallback
    }

    func history(_ name: String, group: String? = nil) -> [MihomoDelayHistory] {
        guard let proxy = proxyMap[name] else { return localHistory[name] ?? [] }
        if independentLatencyTest, let group {
            let url = testURL(for: group)
            if let extra = proxy.extra[url], !extra.isEmpty { return extra }
        }
        if proxy.history.isEmpty { return localHistory[name] ?? [] }
        return proxy.history
    }

    func latency(_ name: String, group: String? = nil) -> Int {
        // 组的延迟取其当前选中节点（原版 LatencyTag 传 group.now）。
        history(name, group: group).last?.delay ?? mihomoNotConnected
    }

    enum LatencyLevel { case none, low, medium, high }

    func level(_ latency: Int) -> LatencyLevel {
        if latency == mihomoNotConnected { return .none }
        if latency < lowLatency { return .low }
        if latency < mediumLatency { return .medium }
        return .high
    }

    // MARK: 排序过滤（P-S01…P-S04）

    func renderProxies(of group: String) -> [String] {
        var names = proxyMap[group]?.all ?? []
        if hideUnavailableProxies {
            names = names.filter { isProxyGroupLike($0) || latency($0, group: group) > mihomoNotConnected }
        }
        let keywords = filter.lowercased().split(separator: " ").map { String($0) }.filter { !$0.isEmpty }
        if !keywords.isEmpty {
            names = names.filter { name in
                let lower = name.lowercased()
                return keywords.allSatisfy { lower.contains($0) }
            }
        }
        if useSmartGroupSort, let order = smartOrder[group] {
            return names.sorted { (order[$0] ?? .max) < (order[$1] ?? .max) }
        }
        if sortType == .defaultsort { return names }
        let groups = names.filter { isProxyGroupLike($0) }
        var nodes = names.filter { !isProxyGroupLike($0) }
        func sortLatency(_ n: String) -> Int {
            let l = latency(n, group: group)
            return l == 0 ? .max : l
        }
        switch sortType {
        case .nameasc: nodes.sort { $0.localizedCompare($1) == .orderedAscending }
        case .namedesc: nodes.sort { $0.localizedCompare($1) == .orderedDescending }
        case .latencyasc: nodes.sort { sortLatency($0) < sortLatency($1) }
        case .latencydesc: nodes.sort { sortLatency($0) > sortLatency($1) }
        case .defaultsort: break
        }
        return groups + nodes
    }

    func availabilityText(of group: String) -> String {
        let all = proxyMap[group]?.all ?? []
        let alive = all.filter { latency($0, group: group) != mihomoNotConnected }.count
        return "\(alive)/\(all.count)"
    }

    // MARK: 链路（P-G03 · 策略穿透）

    /// 递归取组当前最终节点。
    func nowNodeName(_ name: String) -> String {
        var visited: Set<String> = []
        var current = name
        while let now = proxyMap[current]?.now, !visited.contains(current), isGroup(current) {
            visited.insert(current)
            current = now
        }
        return current
    }

    /// 组 → 子组 → 最终节点（不含组自身）。
    func routeChain(_ name: String) -> [String] {
        var chain: [String] = []
        var visited: Set<String> = [name]
        var current = name
        while let now = proxyMap[current]?.now, !visited.contains(now) {
            chain.append(now)
            visited.insert(now)
            guard isGroup(now) else { break }
            current = now
        }
        return chain
    }

    /// 从组本身开始、沿当前选择向下的组链（原版 getProxyGroupChains）。
    func groupChain(_ name: String) -> [String] {
        [name] + routeChain(name).filter { isGroup($0) }
    }

    func descendantGroups(_ name: String) -> [String] {
        var result: [String] = []
        var visited: Set<String> = [name]
        var queue = (proxyMap[name]?.all ?? []).filter { isGroup($0) }
        while !queue.isEmpty {
            let next = queue.removeFirst()
            guard !visited.contains(next) else { continue }
            visited.insert(next)
            result.append(next)
            queue.append(contentsOf: (proxyMap[next]?.all ?? []).filter { isGroup($0) })
        }
        return result
    }

    func descendantNames(_ name: String) -> [String] {
        var result: Set<String> = []
        var visited: Set<String> = [name]
        var queue = proxyMap[name]?.all ?? []
        while !queue.isEmpty {
            let next = queue.removeFirst()
            guard !visited.contains(next) else { continue }
            visited.insert(next)
            result.insert(next)
            queue.append(contentsOf: proxyMap[next]?.all ?? [])
        }
        return Array(result)
    }

    func isFixed(_ group: String) -> Bool {
        guard let proxy = proxyMap[group], let fixed = proxy.fixed else { return false }
        return fixed == proxy.now
    }

    // MARK: 选择（P-N05 · P-N06）

    func select(group: String, node: String) async {
        guard let api, let proxyGroup = proxyMap[group] else { return }
        if proxyGroup.type.lowercased() == "loadbalance" { return }
        if proxyGroup.now == node {
            await fetchProxies()
            if proxyMap[group]?.now == node { return }
        }
        do {
            try await api.select(group: group, name: node)
            proxyMap[group]?.now = node
            if automaticDisconnection {
                let targets = activeConnections.filter { $0.chains.contains(group) }
                for conn in targets { try? await api.closeConnection(conn.id) }
            }
            await fetchProxies()
        } catch {
            post(PPNotice(id: "select", title: "切换失败", detail: error.localizedDescription, kind: .error))
        }
    }

    func setMode(_ mode: String) async {
        guard let api else { return }
        do {
            try await api.patchConfig(["mode": mode])
            config?.mode = mode
            await fetchProxies()
        } catch {
            post(PPNotice(id: "mode", title: "切换模式失败", detail: error.localizedDescription, kind: .error))
        }
    }

    // MARK: 测速（P-G16 · P-C04 · P-T01…）

    private func latencyForSingle(_ api: MihomoAPI, _ name: String, url: String, timeout: Int) async -> (delay: Int, ok: Bool) {
        let now = nowNodeName(name)
        if ipv6Test {
            let v6 = await nodeDelay(api, now, url: Self.ipv6TestURL, timeout: 2000)
            ipv6Map[now] = v6.delay > mihomoNotConnected
            PPPersist.save(ipv6Map, "ipv6Map")
        }
        return await nodeDelay(api, independentLatencyTest ? name : now, url: url, timeout: timeout)
    }

    private func nodeDelay(_ api: MihomoAPI, _ name: String, url: String, timeout: Int) async -> (delay: Int, ok: Bool) {
        if let provider = proxyMap[name]?.providerName, providers.contains(where: { $0.name == provider }) {
            return await api.providerDelay(provider: provider, proxy: name, url: url, timeout: timeout)
        }
        return await api.delay(proxy: name, url: url, timeout: timeout)
    }

    private func noticeName(_ name: String, url: String) -> String {
        independentLatencyTest ? "\(name)\n@\(url)" : name
    }

    /// 单节点测速（P-N03）。
    func testNode(_ name: String, group: String?) async {
        guard let api else { return }
        let key = "node:\(group ?? "")/\(name)"
        guard !testingKeys.contains(key) else { return }
        testingKeys.insert(key)
        defer { testingKeys.remove(key) }
        let url = testURL(for: group)
        let result = await latencyForSingle(api, name, url: url, timeout: speedtestTimeout)
        await fetchProxies()
        if !result.ok {
            post(PPNotice(id: "single:\(name)", title: noticeName(name, url: url), detail: "测速超时", kind: .error), autoDismiss: 3)
        }
    }

    /// 逐个测速（5 路并发，超时 ≤1.5s，进度通知原地更新）。
    private func testOneByOne(scope: String, nodes: [String], url: String, displayName: String, keyName: String) async {
        guard let api, !nodes.isEmpty else { return }
        let total = nodes.count
        var done = 0
        var failed = 0
        let timeout = min(1500, speedtestTimeout)
        let noticeID = "test:\(keyName)"
        await withTaskGroup(of: (String, Int, Bool).self) { group in
            var iterator = nodes.makeIterator()
            func addNext() {
                guard let name = iterator.next() else { return }
                group.addTask { [self] in
                    let r = await self.latencyForSingle(api, name, url: url, timeout: timeout)
                    return (name, r.delay, r.ok)
                }
            }
            for _ in 0..<5 { addNext() }
            for await (name, delay, ok) in group {
                if !ok { failed += 1 }
                appendLocalHistory(name, delay: ok ? delay : mihomoNotConnected)
                done += 1
                post(PPNotice(id: noticeID, title: noticeName(displayName, url: url), detail: "\(done)/\(total) 测试完成", kind: .info))
                addNext()
            }
        }
        post(PPNotice(id: noticeID, title: noticeName(displayName, url: url),
                      detail: "测试完成：\(total - failed) 成功，\(failed) 超时",
                      kind: failed > 0 ? .warning : .success), autoDismiss: 3)
        await fetchProxies()
    }

    private func appendLocalHistory(_ name: String, delay: Int) {
        let entry = MihomoDelayHistory(time: ISO8601DateFormatter().string(from: Date()), delay: delay)
        if proxyMap[name] != nil, !(proxyMap[name]?.history.isEmpty ?? true) {
            proxyMap[name]?.history.append(entry)
        } else {
            localHistory[name, default: []].append(entry)
        }
    }

    /// 组测速（P-G16）。
    func testGroup(_ group: String) async {
        guard let api, let proxy = proxyMap[group] else { return }
        let key = "group:\(group)"
        guard !testingKeys.contains(key) else { return }
        testingKeys.insert(key)
        defer { testingKeys.remove(key) }
        let all = proxy.all ?? []
        let url = testURL(for: group)
        let type = proxy.type.lowercased()
        if ["selector", "loadbalance", "smart"].contains(type) {
            if proxy.fixed != nil { try? await api.deleteFixed(group: group) }
            await testOneByOne(scope: group, nodes: all, url: url, displayName: group, keyName: group)
            return
        }
        let timeout = max(5000, speedtestTimeout)
        if ipv6Test {
            let result = (try? await api.groupDelay(group: group, url: Self.ipv6TestURL, timeout: timeout)) ?? [:]
            for name in all { ipv6Map[nowNodeName(name)] = (result[name] ?? 0) > mihomoNotConnected }
            PPPersist.save(ipv6Map, "ipv6Map")
        }
        _ = try? await api.groupDelay(group: group, url: url, timeout: timeout)
        await fetchProxies()
        let failed = all.filter { latency($0, group: group) == mihomoNotConnected }.count
        post(PPNotice(id: "test:\(group)", title: noticeName(group, url: url),
                      detail: "测试完成：\(all.count - failed) 成功，\(failed) 超时",
                      kind: failed > 0 ? .warning : .success), autoDismiss: 3)
    }

    /// 分类/子集测速（订阅分类用）。
    func testNodes(scope: String, nodes: [String], displayName: String, keyName: String) async {
        let key = "nodes:\(keyName)"
        guard !testingKeys.contains(key) else { return }
        testingKeys.insert(key)
        defer { testingKeys.remove(key) }
        await testOneByOne(scope: scope, nodes: nodes, url: testURL(for: scope), displayName: displayName, keyName: keyName)
    }

    /// 全部测速（P-C04）。
    func testAll() async {
        let key = "all"
        guard !testingKeys.contains(key) else { return }
        testingKeys.insert(key)
        defer { testingKeys.remove(key) }
        if independentLatencyTest {
            await withTaskGroup(of: Void.self) { group in
                var iterator = proxyGroupList.makeIterator()
                func addNext() {
                    guard let name = iterator.next() else { return }
                    group.addTask { [self] in await self.testGroup(name) }
                }
                for _ in 0..<3 { addNext() }
                for await _ in group { addNext() }
            }
            return
        }
        let nodes = proxyMap.keys.filter { !isProxyGroupLike($0) }.sorted()
        await testOneByOne(scope: "all", nodes: nodes, url: testURL(for: nil), displayName: "全部", keyName: "all")
    }

    func isTesting(_ key: String) -> Bool { testingKeys.contains(key) }

    // MARK: 订阅（P-V03）

    func updateProvider(_ name: String) async {
        guard let api else { return }
        testingKeys.insert("update:\(name)")
        defer { testingKeys.remove("update:\(name)") }
        do {
            try await api.updateProvider(name)
            post(PPNotice(id: "update:\(name)", title: name, detail: "更新完成", kind: .success), autoDismiss: 3)
        } catch {
            post(PPNotice(id: "update:\(name)", title: name, detail: error.localizedDescription, kind: .error), autoDismiss: 4)
        }
        await fetchProxies()
    }

    func updateAllProviders() async {
        testingKeys.insert("updateAll")
        defer { testingKeys.remove("updateAll") }
        var done = 0
        for provider in providers where provider.vehicleType != "Inline" {
            await updateProvider(provider.name)
            done += 1
            post(PPNotice(id: "updateAll", title: "订阅", detail: "\(done) 更新完成", kind: .info))
        }
        post(PPNotice(id: "updateAll", title: "订阅", detail: "\(done) 更新完成", kind: .success), autoDismiss: 3)
    }

    func healthCheckProvider(_ name: String) async {
        guard let api else { return }
        testingKeys.insert("health:\(name)")
        defer { testingKeys.remove("health:\(name)") }
        try? await api.healthCheckProvider(name)
        await fetchProxies()
    }

    // MARK: 连接推送（P-G08）

    private func startConnectionStream() {
        guard connectionTask == nil, let api else { return }
        connectionTask = Task { [weak self] in
            for await snapshot in api.connectionsStream() {
                guard let self, !Task.isCancelled else { break }
                self.consume(snapshot)
            }
        }
    }

    private func consume(_ snapshot: MihomoConnectionsSnapshot) {
        let connections = snapshot.connections ?? []
        let now = Date()
        let elapsed = lastConnectionTime.map { max(now.timeIntervalSince($0), 0.2) } ?? 1
        var speed: [String: Int64] = [:]
        var bytes: [String: Int64] = [:]
        for conn in connections {
            bytes[conn.id] = conn.download
            let delta = max(0, conn.download - (lastConnectionBytes[conn.id] ?? conn.download))
            let rate = Int64(Double(delta) / elapsed)
            guard rate > 0 else { continue }
            for chain in conn.chains { speed[chain, default: 0] += rate }
        }
        activeConnections = connections
        lastConnectionBytes = bytes
        lastConnectionTime = now
        if groupDownloadSpeed != speed { groupDownloadSpeed = speed }
    }

    // MARK: 自动刷新（P-D11）

    private func refreshInterval(_ name: String) -> TimeInterval? {
        guard let proxy = proxyMap[name], proxy.history.count >= 2 else { return nil }
        let times = proxy.history.compactMap { PPPersist.parseDate($0.time) }
        guard times.count >= 2 else { return nil }
        let intervals = zip(times.dropFirst(), times).map { $0.timeIntervalSince($1) }.filter { $0 > 0 }
        guard !intervals.isEmpty else { return nil }
        let sorted = intervals.sorted()
        let median = sorted[sorted.count / 2]
        let autoTypes: Set<String> = ["urltest", "fallback", "loadbalance", "smart"]
        if autoTypes.contains(proxy.type.lowercased()) { return median }
        // 间隔稳定（全部落在中位数 ±20% 内）才认为是核心定时测速。
        let stable = intervals.allSatisfy { abs($0 - median) <= median * 0.2 }
        return stable ? median : nil
    }

    private func scheduleAutoRefresh() {
        autoRefreshTask?.cancel()
        guard connectionTask != nil else { return }
        var candidates: Set<String> = []
        switch tab {
        case .provider:
            providers.forEach { $0.proxies.forEach { candidates.insert($0.name) } }
        case .node:
            nodeGroupBlocks.flatMap { $0 }.forEach { candidates.insert($0); descendantNames($0).forEach { candidates.insert($0) } }
        case .policy, .domain:
            policyGroups.forEach { candidates.insert($0); descendantNames($0).forEach { candidates.insert($0) } }
        }
        var next: (due: Date, interval: TimeInterval)?
        for name in candidates {
            guard let interval = refreshInterval(name),
                  let last = proxyMap[name]?.history.last.flatMap({ PPPersist.parseDate($0.time) }) else { continue }
            let due = last.addingTimeInterval(interval)
            if next == nil || due < next!.due { next = (due, interval) }
        }
        guard let schedule = next else { return }
        var fireAt = schedule.due.addingTimeInterval(30)
        let now = Date()
        if fireAt <= now {
            let behind = floor(now.timeIntervalSince(fireAt) / schedule.interval) + 1
            fireAt = fireAt.addingTimeInterval(behind * schedule.interval)
        }
        let delay = max(1, fireAt.timeIntervalSince(now))
        autoRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.fetchProxies()
        }
    }

    // MARK: 通知

    func post(_ notice: PPNotice, autoDismiss seconds: Double? = nil) {
        if let index = notices.firstIndex(where: { $0.id == notice.id }) {
            notices[index] = notice
        } else {
            notices.append(notice)
        }
        guard let seconds else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self?.notices.removeAll { $0 == notice }
        }
    }

    func dismiss(_ id: String) { notices.removeAll { $0.id == id } }
}

/// 小型持久化工具：界面状态字典存 UserDefaults（前缀 pp.）。
enum PPPersist {
    static func dict<V: Codable>(_ key: String) -> [String: V] {
        guard let data = UserDefaults.standard.data(forKey: "pp." + key),
              let value = try? JSONDecoder().decode([String: V].self, from: data) else { return [:] }
        return value
    }

    static func save<V: Codable>(_ value: [String: V], _ key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: "pp." + key) }
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso = ISO8601DateFormatter()

    /// Mihomo 的时间带纳秒（9 位小数），ISO8601DateFormatter 只认 3 位：先去掉小数部分。
    static func parseDate(_ string: String) -> Date? {
        if let d = isoFractional.date(from: string) ?? iso.date(from: string) { return d }
        let trimmed = string.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return iso.date(from: trimmed)
    }
}
