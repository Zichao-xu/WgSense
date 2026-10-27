import AppKit
import CoreWLAN
import Foundation

// 测速台的引擎与状态：端点名册、场景、一次测量的编排、历史。
//
// 磁贴和页面共用这一个实例：从哪里开测都是同一次测量，切页不中断。
// 空闲时零开销——没有轮询、没有常驻连接；事件解析在后台线程，主线程每秒只收一次读数。

@MainActor
final class SpeedLabStore: ObservableObject {
    static let shared = SpeedLabStore()

    // MARK: 名册与选择

    @Published private(set) var peers: [SLEndpoint] = []
    @Published var manual: [SLEndpoint] = [] { didSet { save(manual, Keys.manual) } }
    @Published var savedScenes: [SLScene] = [] { didSet { save(savedScenes, Keys.scenes) } }
    @Published var runnerID: String = SLEndpoint.local.id { didSet { defaults.set(runnerID, forKey: Keys.runner) } }
    @Published var targetID: String = SLEndpoint.publicNet.id { didSet { defaults.set(targetID, forKey: Keys.target) } }
    @Published var path: SLPathMode = .direct { didSet { defaults.set(path.rawValue, forKey: Keys.path) } }
    @Published var params = SLParams() { didSet { save(params, Keys.params) } }
    /// 用户手动添加的源（远程源列表见 SLSourceCatalog）。
    @Published var downloadSources: [String] = [] { didSet { save(downloadSources, Keys.dlSources) } }
    @Published var uploadSources: [String] = [] { didSet { save(uploadSources, Keys.ulSources) } }
    /// 本次被跳过的方向（没有可用源）。
    @Published private(set) var skipped: Set<String> = []

    // MARK: 一次测量

    @Published private(set) var running = false
    @Published private(set) var phase: SLPhase = .prepare
    @Published private(set) var downNow: Double?
    @Published private(set) var upNow: Double?
    @Published private(set) var rttNow: Double?
    @Published private(set) var downSeries: [Double] = []
    @Published private(set) var upSeries: [Double] = []
    @Published private(set) var info: [String: String] = [:]
    @Published private(set) var note: String = ""
    @Published private(set) var error: String?
    /// 表盘满刻度（Mbps）：开测时按协商速率定，跑中只在超出时放大，不来回缩放。
    @Published private(set) var scaleMax: Double = 1000
    @Published private(set) var history: [SLResult] = []

    private var task: Task<Void, Never>?
    private(set) var idleRTTs: [Double] = []
    private(set) var downRTTs: [Double] = []
    private(set) var upRTTs: [Double] = []

    // 动效时间线：每个事件带到达时刻，HUD 按"触发后第几帧"取动作
    @Published private(set) var startedAt: Date?
    @Published private(set) var finishedAt: Date?
    @Published private(set) var phaseDates: [SLPhase: Date] = [:]
    @Published private(set) var infoDates: [String: Date] = [:]
    @Published private(set) var downTimed: [SLTimedSample] = []
    @Published private(set) var upTimed: [SLTimedSample] = []
    @Published private(set) var idleTimed: [SLTimedSample] = []
    @Published private(set) var sourceResults: [SLSourceResult] = []
    @Published private(set) var reconnects: [SLConnEvent] = []
    private var capabilities: [String: [String: String]] = [:]
    private var discoveredOnce = false
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let manual = "speedLab.manualEndpoints"
        static let peers = "speedLab.peers"
        static let scenes = "speedLab.scenes"
        static let runner = "speedLab.runner"
        static let target = "speedLab.target"
        static let path = "speedLab.path"
        static let params = "speedLab.params"
        static let dlSources = "speedLab.downloadSources"
        static let ulSources = "speedLab.uploadSources"
    }

    private init() {
        manual = load(Keys.manual) ?? []
        peers = load(Keys.peers) ?? []
        savedScenes = load(Keys.scenes) ?? []
        params = load(Keys.params) ?? SLParams()
        downloadSources = load(Keys.dlSources) ?? []
        uploadSources = load(Keys.ulSources) ?? []
        SLSourceCatalog.shared.refreshIfStale()
        path = SLPathMode(rawValue: defaults.string(forKey: Keys.path) ?? "") ?? .direct
        history = Self.loadHistory()
        // 首次：执行端默认给路由器（有的话），测宽带最常用。
        if let runner = defaults.string(forKey: Keys.runner) {
            runnerID = runner
        } else if let router = routers.first {
            runnerID = router.id
        }
        targetID = defaults.string(forKey: Keys.target) ?? SLEndpoint.publicNet.id
    }

    // MARK: - 名册

    /// 代理后端里配了 SSH 的路由器（规则源也走这条 SSH）。
    var routers: [SLEndpoint] {
        var seen = Set<String>()
        return MihomoBackendStore.shared.backends.compactMap { backend in
            let host = backend.effectiveSSHHost
            guard !host.isEmpty else { return nil }
            let endpoint = SLEndpoint.ssh(name: backend.label.isEmpty ? host : backend.label, host: host,
                                          port: backend.sshPort, user: backend.sshUser, origin: "代理后端")
            return seen.insert(endpoint.id).inserted ? endpoint : nil
        }
    }

    /// 全部端点：本机 → 路由器 → 手动 → WG peer → 公网。
    var endpoints: [SLEndpoint] {
        var list = [SLEndpoint.local] + routers
        for item in manual where !list.contains(where: { $0.id == item.id }) { list.append(item) }
        let sshHosts = Set(list.map(\.host))
        for peer in peers where !sshHosts.contains(peer.host) { list.append(peer) }
        list.append(.publicNet)
        return list
    }

    var runners: [SLEndpoint] { endpoints.filter(\.canRun) }
    var runner: SLEndpoint? { endpoints.first { $0.id == runnerID } }
    var target: SLEndpoint? { endpoints.first { $0.id == targetID } }

    /// 当前组合不能测的原因；能测为空。
    var blocker: String? {
        guard let runner else { return "选择执行端" }
        guard let target else { return "选择目标" }
        if runner.id == target.id { return "执行端和目标是同一台机器" }
        if target.kind == .local, runner.kind == .local { return "执行端和目标是同一台机器" }
        return nil
    }

    /// 目标为公网时才有路径可选；其余由地址决定走哪张网卡（台账里注明）。
    var pathSelectable: Bool { target?.isPublic ?? false }

    func addManual(name: String, host: String, port: Int, user: String) {
        let endpoint = SLEndpoint.ssh(name: name.isEmpty ? host : name, host: host, port: port, user: user, origin: "手动添加")
        manual.removeAll { $0.id == endpoint.id }
        manual.append(endpoint)
    }

    func removeManual(_ endpoint: SLEndpoint) {
        manual.removeAll { $0.id == endpoint.id }
        if runnerID == endpoint.id { runnerID = SLEndpoint.local.id }
        if targetID == endpoint.id { targetID = SLEndpoint.publicNet.id }
    }

    /// 从路由器上发现 WG peer（每次打开页面最多一次；结果缓存，下次启动直接可用）。
    func discoverPeersIfNeeded() {
        guard !discoveredOnce, !running else { return }
        discoveredOnce = true
        let sources = routers + manual
        guard !sources.isEmpty else { return }
        Task {
            var found: [SLEndpoint] = []
            for endpoint in sources {
                guard let events = try? await SLShell(endpoint: endpoint).collect(["MODE": "probe"]) else { continue }
                remember(endpoint, events)
                for event in events where event.ev == "peer" {
                    guard let ip = event.ip, !found.contains(where: { $0.host == ip }) else { continue }
                    found.append(.peer(name: event.name ?? ip, ip: ip))
                }
            }
            let mine = Self.localIPv4s()
            found.removeAll { mine.contains($0.host) }
            guard !found.isEmpty else { return }
            peers = found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            save(peers, Keys.peers)
        }
    }

    // MARK: - 场景

    var builtInScenes: [SLScene] {
        var list: [SLScene] = []
        if let router = routers.first {
            list.append(SLScene(title: "宽带", runnerID: router.id, targetID: SLEndpoint.publicNet.id, path: .direct, builtIn: true))
            list.append(SLScene(title: "隧道", runnerID: SLEndpoint.local.id, targetID: router.id, path: .system, builtIn: true))
        }
        list.append(SLScene(title: "本机上网", runnerID: SLEndpoint.local.id, targetID: SLEndpoint.publicNet.id, path: .system, builtIn: true))
        return list
    }

    var scenes: [SLScene] { builtInScenes + savedScenes }

    func isCurrent(_ scene: SLScene) -> Bool {
        scene.runnerID == runnerID && scene.targetID == targetID && (!pathSelectable || scene.path == path)
    }

    func apply(_ scene: SLScene) {
        guard !running else { return }
        runnerID = scene.runnerID
        targetID = scene.targetID
        path = scene.path
    }

    func saveCurrentAsScene() {
        guard let runner, let target, blocker == nil else { return }
        let title = target.isPublic ? "\(runner.name)·\(path.title)" : "\(runner.name)→\(target.name)"
        guard !scenes.contains(where: isCurrent) else { return }
        savedScenes.append(SLScene(title: title, runnerID: runnerID, targetID: targetID, path: path))
    }

    func deleteScene(_ scene: SLScene) {
        savedScenes.removeAll { $0.id == scene.id }
    }

    // MARK: - 结果

    var lastResult: SLResult? { history.first }

    /// 当前组合的上一次结果（待机时表盘停在这里）。
    var lastForCurrent: SLResult? {
        guard let runner, let target else { return nil }
        let key = SLResult(runner: runner.name, target: target.name, path: currentPathTitle(target), engine: "").sceneKey
        return history.first { $0.sceneKey == key && $0.error == nil }
    }

    /// 执行端回报的采样间隔（秒）：默认每秒 4 次，执行端不支持亚秒等待时退回 1。
    var tick: Double { info["tick"].flatMap(Double.init) ?? 1 }
    var downStat: SLStat? { SLStat.from(downSeries, rtts: downRTTs, tick: tick) }
    var upStat: SLStat? { SLStat.from(upSeries, rtts: upRTTs, tick: tick) }
    var idleRTT: Double? { idleRTTs.isEmpty ? nil : SLStat.median(idleRTTs) }

    func clearHistory() {
        history = []
        Self.saveHistory(history)
    }

    private func currentPathTitle(_ target: SLEndpoint) -> String {
        target.isPublic ? path.title : "iperf3"
    }

    // MARK: - 运行

    func start() {
        guard !running, blocker == nil, let runner, let target else { return }
        running = true
        phase = .prepare
        downNow = nil; upNow = nil; rttNow = nil
        downSeries = []; upSeries = []
        idleRTTs = []; downRTTs = []; upRTTs = []
        info = [:]; error = nil; note = "连接执行端…"
        startedAt = Date(); finishedAt = nil
        phaseDates = [.prepare: Date()]; infoDates = [:]
        downTimed = []; upTimed = []; idleTimed = []; sourceResults = []; reconnects = []; skipped = []
        scaleMax = 1000
        task = Task { await execute(runner: runner, target: target) }
    }

    func stop() {
        task?.cancel()
    }

    private func execute(runner: SLEndpoint, target: SLEndpoint) async {
        var result = SLResult(runner: runner.name, target: target.name, path: currentPathTitle(target),
                              engine: target.isPublic ? "HTTP" : "iperf3")
        do {
            if target.isPublic {
                try await runHTTP(runner: runner)
            } else {
                try await runIperf(runner: runner, target: target)
            }
            if Task.isCancelled { throw CancellationError() }
        } catch is CancellationError {
            result.error = "已停止"
        } catch {
            result.error = error.localizedDescription
        }
        if Task.isCancelled, result.error == nil { result.error = "已停止" }
        if target.isPublic { SLSourceCatalog.shared.record(sourceResults) }

        result.down = downStat
        result.up = upStat
        result.idleRTT = idleRTT
        result.downSeries = downSeries
        result.upSeries = upSeries
        result.tick = tick
        result.linkText = info["link"] ?? ""
        result.linkMbps = linkMbps
        result.exit = info["exit"] ?? ""
        result.sources = sourceList
        if result.down != nil || result.up != nil || (result.error != nil && result.error != "已停止") {
            history.insert(result, at: 0)
            if history.count > 300 { history.removeLast(history.count - 300) }
            Self.saveHistory(history)
        }
        error = result.error == "已停止" ? nil : result.error
        note = result.error ?? "完成"
        phase = .done
        finishedAt = Date()
        phaseDates[.done] = finishedAt
        running = false
        downNow = nil; upNow = nil
        task = nil
    }

    // MARK: HTTP（公网）

    private func runHTTP(runner: SLEndpoint) async throws {
        note = "公网测速：\(runner.name) · \(path.title)"
        var vars = commonVars()
        vars["MODE"] = "http"
        vars["PATHMODE"] = path.rawValue
        let catalog = SLSourceCatalog.shared
        let dl = catalog.candidates("dl", manual: downloadSources), ul = catalog.candidates("ul", manual: uploadSources)
        guard !dl.isEmpty || !ul.isEmpty else {
            throw SLShell.Failure(message: catalog.url.isEmpty ? "未配置测速源 · 在「测速源」里填源列表地址" : "测速源列表为空")
        }
        vars["DL_URLS"] = dl.joined(separator: " ")
        vars["UL_URLS"] = ul.joined(separator: " ")
        vars["DL_THREADS"] = "\(params.httpDownThreads)"
        vars["UL_THREADS"] = "\(params.httpUpThreads)"
        try await consume(SLShell(endpoint: runner).stream(vars), runner: runner)
    }

    // MARK: iperf3（两端之间）

    private func runIperf(runner: SLEndpoint, target: SLEndpoint) async throws {
        let targetShell = SLShell(endpoint: target)
        var port = params.iperfPort
        var deployed: String?

        // 目标端：能登上去就临时起服务端，测完必停；WG peer 要求它自己开着。
        if target.kind != .peer {
            note = "在 \(target.name) 上启动 iperf3 服务端…"
            let bin = try await ensureIperf(on: target)
            deployed = bin.deployed
            var vars = ["MODE": "iperf-server", "IPERF_PORT": "\(port)"]
            if let path = bin.path { vars["IPERF_BIN"] = path }
            let events = try await targetShell.collect(vars)
            if let p = events.first(where: { $0.k == "port" })?.v.flatMap(Int.init) { port = p }
        }

        do {
            let host = target.kind == .local ? try await Self.localAddress(toward: runner.host) : target.host
            note = "iperf3：\(runner.name) ⇄ \(target.name)"
            let bin = try await ensureIperf(on: runner)
            var vars = commonVars()
            vars["MODE"] = "iperf"
            vars["IPERF_HOST"] = host
            vars["IPERF_PORT"] = "\(port)"
            vars["IPERF_P"] = "\(params.iperfStreams)"
            if let path = bin.path { vars["IPERF_BIN"] = path }
            info["target"] = "\(host):\(port)"
            try await consume(SLShell(endpoint: runner).stream(vars), runner: runner)
            if let deployedRunner = bin.deployed, runner.kind == .ssh {
                _ = try? await SLShell(endpoint: runner).collect(["MODE": "iperf-stop", "DEPLOYED": deployedRunner])
            }
        } catch {
            await stopServer(on: target, deployed: deployed)
            throw error
        }
        await stopServer(on: target, deployed: deployed)
    }

    private func stopServer(on target: SLEndpoint, deployed: String?) async {
        guard target.kind != .peer else { return }
        var vars = ["MODE": "iperf-stop"]
        if let deployed { vars["DEPLOYED"] = deployed }
        // 收尾不受“停止”影响：放到独立任务里跑完。
        await Task.detached { _ = try? await SLShell(endpoint: target).collect(vars) }.value
    }

    /// 这台机器上能用的 iperf3：自带的直接用；没有就把 App 里打包的静态版传过去（测完删除）。
    private func ensureIperf(on endpoint: SLEndpoint) async throws -> (path: String?, deployed: String?) {
        let caps = try await probe(endpoint)
        if caps["has_iperf3"] == "1" { return (nil, nil) }
        let os = (caps["os"] ?? "").lowercased()
        let arch = (caps["arch"] ?? "").lowercased()
        let name = "iperf3-\(os)-\(arch == "arm64" && os == "linux" ? "aarch64" : arch)"
        guard let bundled = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "iperf3") else {
            throw SLShell.Failure(message: "\(endpoint.name) 没有 iperf3，App 里也没有 \(os)/\(arch) 的静态版可部署")
        }
        if endpoint.kind == .local { return (bundled.path, nil) }
        note = "给 \(endpoint.name) 临时部署 iperf3…"
        let remote = "/tmp/wgsense-iperf3"
        try await SLShell(endpoint: endpoint).upload(bundled, to: remote)
        return (remote, remote)
    }

    /// 能力探测（每台机器每次启动探一次）。
    private func probe(_ endpoint: SLEndpoint) async throws -> [String: String] {
        if let cached = capabilities[endpoint.id] { return cached }
        let events = try await SLShell(endpoint: endpoint).collect(["MODE": "probe"])
        return remember(endpoint, events)
    }

    @discardableResult
    private func remember(_ endpoint: SLEndpoint, _ events: [SLEvent]) -> [String: String] {
        var caps: [String: String] = [:]
        for event in events where event.ev == "info" {
            if let k = event.k { caps[k] = event.v ?? "" }
        }
        capabilities[endpoint.id] = caps
        return caps
    }

    // MARK: 事件

    private func commonVars() -> [String: String] {
        ["DUR": "\(params.duration)", "DIRS": params.directions.script]
    }

    private func consume(_ stream: AsyncThrowingStream<SLEvent, Error>, runner: SLEndpoint) async throws {
        for try await event in stream {
            try Task.checkCancellation()
            switch event.ev {
            case "info":
                guard let k = event.k else { break }
                info[k] = event.v ?? ""
                infoDates[k] = Date()
                if k == "link" { applyLink(runner: runner) }
            case "phase":
                if let p = event.ph.flatMap(SLPhase.init(rawValue:)) {
                    phase = p
                    phaseDates[p] = Date()
                    note = p.title
                }
            case "src":
                if let dir = event.ph, let url = event.v {
                    sourceResults.append(SLSourceResult(dir: dir, url: url, mbps: event.rx ?? 0,
                                                        keep: event.keep ?? false, at: Date()))
                }
            case "skip":
                if let dir = event.ph { skipped.insert(dir) }
            case "conn":
                if let dir = event.ph { reconnects.append(SLConnEvent(dir: dir, n: event.n ?? 0, at: Date())) }
            case "s":
                take(event)
            case "err":
                throw SLShell.Failure(message: event.msg ?? "执行端报错")
            default:
                break
            }
        }
    }

    private func take(_ event: SLEvent) {
        let rtt = event.rtt
        rttNow = rtt
        switch event.ph {
        case "idle":
            if let rtt { idleRTTs.append(rtt); idleTimed.append(SLTimedSample(v: rtt, rtt: rtt, at: Date())) }
        case "dl":
            let v = event.rx ?? 0
            downNow = v
            downSeries.append(v)
            downTimed.append(SLTimedSample(v: v, rtt: rtt, at: Date()))
            if let rtt { downRTTs.append(rtt) }
            grow(v)
        case "ul":
            let v = event.tx ?? 0
            upNow = v
            upSeries.append(v)
            upTimed.append(SLTimedSample(v: v, rtt: rtt, at: Date()))
            if let rtt { upRTTs.append(rtt) }
            grow(v)
        default:
            break
        }
    }

    var linkMbps: Int? {
        guard let first = info["link"]?.split(separator: " ").first, let v = Int(first), v > 0 else { return nil }
        return v
    }

    /// 协商速率到手：定表盘满刻度。本机 Wi-Fi 读不到网卡速率时，用 CoreWLAN 的发送速率。
    private func applyLink(runner: SLEndpoint) {
        if linkMbps == nil, runner.kind == .local, let phy = info["phy"],
           let wifi = CWWiFiClient.shared().interface(withName: phy), wifi.transmitRate() > 0 {
            info["link"] = "\(Int(wifi.transmitRate())) Wi-Fi"
        }
        scaleMax = Self.niceScale(Double(linkMbps ?? 1000))
    }

    /// 读数明显超出满刻度才放大（单个采样的毛刺不算）。
    private func grow(_ value: Double) {
        if value > scaleMax * 1.1 { scaleMax = Self.niceScale(value * 1.05) }
    }

    static func niceScale(_ v: Double) -> Double {
        for step in [100.0, 300, 500, 1000, 2500, 5000, 10000, 25000, 40000, 100000] where v <= step { return step }
        return v
    }

    private var sourceList: [String] {
        if let target = info["target"] { return [target] }
        return [info["dl_sources"], info["ul_sources"]].compactMap { $0 }.filter { !$0.isEmpty }
    }

    // MARK: - 本机地址

    /// 本机在通往某台机器那张网卡上的 IPv4（对端要连回本机的 iperf3 服务端）。
    static func localAddress(toward host: String) async throws -> String {
        try await Task.detached {
            let route = Self.shell("/sbin/route", ["-n", "get", host])
            guard let iface = route.split(separator: "\n").first(where: { $0.contains("interface:") })?
                .split(separator: ":").last?.trimmingCharacters(in: .whitespaces) else {
                throw SLShell.Failure(message: "找不到通往 \(host) 的网卡")
            }
            let conf = Self.shell("/sbin/ifconfig", [iface])
            for line in conf.split(separator: "\n") {
                let parts = line.split(separator: " ")
                if let i = parts.firstIndex(of: "inet"), i + 1 < parts.count { return String(parts[i + 1]) }
            }
            throw SLShell.Failure(message: "\(iface) 上没有 IPv4 地址")
        }.value
    }

    static func localIPv4s() -> Set<String> {
        let conf = shell("/sbin/ifconfig", [])
        var set = Set<String>()
        for line in conf.split(separator: "\n") {
            let parts = line.split(separator: " ")
            if let i = parts.firstIndex(of: "inet"), i + 1 < parts.count { set.insert(String(parts[i + 1])) }
        }
        return set
    }

    nonisolated private static func shell(_ exe: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - 持久化

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private func load<T: Decodable>(_ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private static var historyURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WgSense", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("speedlab-history.json")
    }

    private static func loadHistory() -> [SLResult] {
        guard let data = try? Data(contentsOf: historyURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SLResult].self, from: data)) ?? []
    }

    private static func saveHistory(_ history: [SLResult]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(history) else { return }
        try? data.write(to: historyURL, options: .atomic)
    }
}

// MARK: - HUD 快照

extension SLHUDData {
    @MainActor init(_ lab: SpeedLabStore) {
        self.init()
        runner = lab.runner?.name ?? "—"
        target = lab.target?.name ?? "—"
        isPublic = lab.target?.isPublic ?? true
        path = isPublic ? (lab.path == .direct ? "direct" : "system") : "iperf3"
        running = lab.running
        startedAt = lab.startedAt
        finishedAt = lab.finishedAt
        phaseDates = lab.phaseDates
        infoDates = lab.infoDates
        info = lab.info
        link = lab.linkMbps
        down = lab.downTimed
        up = lab.upTimed
        idle = lab.idleTimed
        sources = lab.sourceResults
        reconnects = lab.reconnects
        skipped = lab.skipped
        downThreads = isPublic ? lab.params.httpDownThreads : lab.params.iperfStreams
        upThreads = isPublic ? lab.params.httpUpThreads : lab.params.iperfStreams
        unit = lab.params.unit
        tick = lab.tick
        error = lab.error
    }

}
