import SwiftUI

struct DaemonStatus: Codable {
    var at_home: Bool
    var state: String
    var paused: Bool
    var service: String
}

struct TrafficStats: Codable {
    var tx_speed: Double
    var rx_speed: Double
    var tx_bytes: UInt64
    var rx_bytes: UInt64
}

@MainActor
class DaemonClient: ObservableObject {
    @Published var status: DaemonStatus?
    @Published var profiles: [String] = []
    @Published var errorMsg: String?
    @Published var alertMsg: String?
    @Published var logLines: [String] = []
    @Published var traffic: TrafficStats?

    /// 暂停时长（分钟），可在设置页修改，默认 5
    @AppStorage("pauseMinutes") var pauseMinutes: Int = 5

    // 运行配置（AppStorage 本地缓存 + 同步到 daemon）
    @AppStorage("healthCheckTarget") var healthCheckTarget: String = "https://1.1.1.1"
    @AppStorage("intervalSeconds") var intervalSeconds: Int = 10
    @AppStorage("autoUpGraceSeconds") var autoUpGraceSeconds: Int = 20
    @AppStorage("homeNetworkPrefixes") var homeNetworkPrefixes: String = "10.10.1."

    private let baseURL = URL(string: "http://127.0.0.1:8765")!
    private var pollTimer: Timer?

    /// Daemon 二进制路径（需 sudo 启动）
    private static let daemonPath = "/Users/adams/Projects/wgsense/core/wgsense-daemon"

    /// 是否已确认 daemon 不可达（避免重复检测）
    private var daemonConfirmedDown = false

    init() {
        startPolling()
    }

    // MARK: - 连通性检测（1s 超时，极速判定）

    /// 检测 daemon 是否在线，1 秒超时
    func isDaemonReachable() -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var reachable = false
        var req = URLRequest(url: baseURL.appendingPathComponent("api/status"))
        req.timeoutInterval = 1.0
        req.httpMethod = "GET"
        Task {
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    reachable = true
                }
            } catch { /* 超时/拒绝 = 不可达 */ }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 1.5)
        return reachable
    }

    /// 确保 daemon 在线：先快速检测，不可达则提示用户启动
    func ensureDaemon() async -> Bool {
        if daemonConfirmedDown { return false }

        // 异步快速检测（不阻塞 UI）
        let reachable = await withCheckedContinuation { continuation in
            var req = URLRequest(url: baseURL.appendingPathComponent("api/status"))
            req.timeoutInterval = 1.0
            Task {
                do {
                    let (_, resp) = try await URLSession.shared.data(for: req)
                    let ok = (resp as? HTTPURLResponse)?.statusCode == 200
                    continuation.resume(returning: ok)
                } catch {
                    continuation.resume(returning: false)
                }
            }
        }

        if reachable {
            daemonConfirmedDown = false
            return true
        }

        daemonConfirmedDown = true
        errorMsg = "⚠️ Daemon 未运行 — 请在终端执行：sudo \(Self.daemonPath) --api 127.0.0.1:8765"
        return false
    }

    /// 重置可达状态（供轮询成功后调用）
    func markDaemonUp() {
        daemonConfirmedDown = false
        errorMsg = nil
    }

    deinit {
        pollTimer?.invalidate()
    }

    /// 启动定时轮询，确保菜单栏图标状态始终最新
    func startPolling(interval: TimeInterval = 2.0) {
        pollTimer?.invalidate()
        var tick = 0
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                await self.fetchStatus()
                // 每 3 次轮询拉一次流量（约 6 秒间隔）
                tick += 1
                if tick % 3 == 0 { await self.fetchTraffic() }
            }
        }
        // 立即拉一次
        Task { await fetchStatus(); await fetchTraffic() }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func refresh() async {
        await fetchStatus()
        await fetchProfiles()
        await fetchTraffic()
    }

    func fetchStatus() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("api/status"))
            status = try JSONDecoder().decode(DaemonStatus.self, from: data)
            markDaemonUp()
        } catch {
            status = nil
            errorMsg = "daemon 未连接"
        }
    }

    func fetchProfiles() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("api/profiles"))
            profiles = try JSONDecoder().decode([String].self, from: data)
        } catch {
            // daemon 离线时从文件系统直读
            profiles = loadProfilesFromDisk()
        }
    }

    /// 拉取最近 N 行日志（供小磁贴日志滚动用）
    func fetchLogs(n: Int = 15) async {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/logs"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "n", value: "\(n)")]
        guard let url = components.url else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let result = try? JSONDecoder().decode(LogsResponse.self, from: data) {
                logLines = result.lines
            }
        } catch { /* daemon 可能还没启动 */ }
    }

    /// 拉取实时流量统计
    func fetchTraffic() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("api/traffic"))
            traffic = try JSONDecoder().decode(TrafficStats.self, from: data)
        } catch { traffic = nil }
    }

    struct LogsResponse: Codable {
        let lines: [String]
        let count: Int
    }

    func post(_ endpoint: String) async {
        guard await ensureDaemon() else { return }

        let oldStatus = status
        optimisticUpdate(endpoint)

        var req = URLRequest(url: baseURL.appendingPathComponent("api/\(endpoint)"))
        req.httpMethod = "POST"
        req.timeoutInterval = 3.0

        Task {
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    markDaemonUp()
                    await fetchStatus()
                } else {
                    await revertAndAlert(oldStatus, "操作失败：\(endpoint)")
                }
            } catch {
                await revertAndAlert(oldStatus, "无法连接 daemon")
            }
        }
    }

    /// 发送 POST 并等待完成（用于需要严格顺序的操作）
    func postAndWait(_ endpoint: String) async {
        guard await ensureDaemon() else { return }

        let oldStatus = status
        optimisticUpdate(endpoint)
        var req = URLRequest(url: baseURL.appendingPathComponent("api/\(endpoint)"))
        req.httpMethod = "POST"
        req.timeoutInterval = 3.0
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                markDaemonUp()
                await fetchStatus()
            } else {
                await revertAndAlert(oldStatus, "操作失败：\(endpoint)")
            }
        } catch {
            await revertAndAlert(oldStatus, "无法连接 daemon")
        }
    }

    /// 回退状态：连接失败只设置 inline errorMsg，不再弹模态框
    @MainActor
    private func revertAndAlert(_ oldStatus: DaemonStatus?, _ msg: String) {
        status = oldStatus
        // 只对非连接类错误弹窗（连接失败用 errorMsg 内联显示即可）
        if !msg.contains("Could not connect") && !msg.contains("无法连接") {
            alertMsg = msg
        } else {
            errorMsg = "daemon 未运行"
        }
    }

    // MARK: - Profile 文件系统直读（daemon 离线兜底）
    private static let profileDirURL: URL = {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".local/share/wgsense/profiles")
    }()

    /// 从文件系统直接读取 profile 列表（不依赖 daemon）
    private func loadProfilesFromDisk() -> [String] {
        let fm = FileManager.default
        var result: [String] = []
        guard let files = try? fm.contentsOfDirectory(at: Self.profileDirURL,
                                                       includingPropertiesForKeys: [.isRegularFileKey]) else {
            return result
        }
        for url in files {
            if url.pathExtension == "conf" {
                result.append(url.deletingPathExtension().lastPathComponent)
            }
        }
        return result.sorted()
    }

    /// 直接写入 .conf 到文件系统（daemon 离线也能导入）
    private func saveProfileToDisk(_ name: String, _ content: String) throws {
        let dir = Self.profileDirURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileUrl = dir.appendingPathComponent(name + ".conf")
        try? content.write(to: fileUrl, atomically: true, encoding: .utf8)
    }

    /// 直接从文件系统删除 profile
    private func deleteProfileFromDisk(_ name: String) throws {
        let fileUrl = Self.profileDirURL.appendingPathComponent(name + ".conf")
        try FileManager.default.removeItem(at: fileUrl)
    }

    /// 乐观更新：点击按钮后立即更新 UI 显示的状态
    private func optimisticUpdate(_ endpoint: String) {
        guard var s = status else { return }
        switch endpoint {
        case "connect":
            s.state = "Connected"
        case "disconnect":
            s.state = "Disconnected"
        case "pause":
            s.paused = true
        case "resume":
            s.paused = false
        default:
            break
        }
        status = s
    }

    // MARK: - Profile 管理

    func importProfile(name: String, content: String) async {
        // 1. 先直接写文件（保证即使 daemon 离线也能导入成功）
        do {
            try saveProfileToDisk(name, content)
        } catch { /* 继续尝试 daemon */ }
        // 2. 再通知 daemon（如果在线）
        let body: [String: String] = ["name": name, "content": content]
        var req = URLRequest(url: baseURL.appendingPathComponent("api/profile/import"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }

    /// 导出 profile 内容（先读磁盘，daemon 作为备选）
    func exportProfile(name: String) async -> String {
        // 优先从本地文件读取
        let fileUrl = Self.profileDirURL.appendingPathComponent(name + ".conf")
        if let content = try? String(contentsOf: fileUrl, encoding: .utf8) {
            return content
        }
        // daemon 备选
        var components = URLComponents(url: baseURL.appendingPathComponent("api/profile/export"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let url = components.url else { return "" }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let result = try JSONDecoder().decode(ExportResponse.self, from: data)
            return result.content
        } catch { return "" }
    }

    /// 加载 profile 内容供编辑（直接读磁盘）
    func loadProfileContent(name: String) async -> String {
        let fileUrl = Self.profileDirURL.appendingPathComponent(name + ".conf")
        return (try? String(contentsOf: fileUrl, encoding: .utf8)) ?? ""
    }

    /// 切换当前使用的 profile（复制为 default.conf → 重连）
    func switchProfile(_ name: String) async {
        // 1. 读取目标 profile 内容
        let srcUrl = Self.profileDirURL.appendingPathComponent(name + ".conf")
        guard let content = try? String(contentsOf: srcUrl, encoding: .utf8) else { return }

        // 2. 写到 default.conf（ daemon 的默认配置路径）
        let defaultConfPath = "\(NSHomeDirectory())/.local/share/wgsense/profiles/default.conf"
        let defaultUrl = URL(fileURLWithPath: defaultConfPath)
        try? content.write(to: defaultUrl, atomically: true, encoding: .utf8)

        // 3. 断开再连接（让 daemon 用新配置）
        await postAndWait("disconnect")
        try? await Task.sleep(for: .milliseconds(300))
        await postAndWait("connect")
        await fetchStatus()
    }

    func saveProfile(_ profile: WGProfile) async {
        // 1. 先直接写 .conf 文件
        let conf = """
        [Interface]
        PrivateKey = \(profile.privateKey)
        Address = \(profile.address)
        DNS = \(profile.dns)
        MTU = \(profile.mtu)

        [Peer]
        PublicKey = \(profile.publicKey)
        PresharedKey = \(profile.presharedKey)
        Endpoint = \(profile.endpoint)
        AllowedIPs = \(profile.allowedIPs)
        PersistentKeepalive = \(profile.keepalive)
        """
        do { try saveProfileToDisk(profile.name, conf) } catch { /* continue */ }
        // 2. 再通知 daemon
        let body: [String: Any] = [
            "Name": profile.name,
            "Interface": [
                "PrivateKey": profile.privateKey,
                "Address": profile.address,
                "DNS": profile.dns,
                "MTU": profile.mtu
            ],
            "Peers": [[
                "PublicKey": profile.publicKey,
                "PresharedKey": profile.presharedKey,
                "Endpoint": profile.endpoint,
                "AllowedIPs": profile.allowedIPs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
                "PersistentKeepaliveInterval": profile.keepalive
            ]]
        ]
        var req = URLRequest(url: baseURL.appendingPathComponent("api/profile/save"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }

    func deleteProfile(name: String) async {
        // 1. 先直接删文件
        do { try deleteProfileFromDisk(name) } catch { /* continue */ }
        // 2. 再通知 daemon
        var components = URLComponents(url: baseURL.appendingPathComponent("api/profile/delete"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let url = components.url else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - 配置同步

    func syncConfig() async {
        let prefixes = homeNetworkPrefixes
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let body: [String: Any] = [
            "home_network_prefixes": prefixes,
            "interval_seconds": intervalSeconds,
            "auto_up_grace_seconds": autoUpGraceSeconds,
            "health_check_target": healthCheckTarget,
            "health_check_interval_seconds": 30
        ]
        var req = URLRequest(url: baseURL.appendingPathComponent("api/config"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Profile 切换

    /// 更新 profile 内容（写磁盘 + 同步 default）
    func updateProfile(name: String, content: String) async {
        // 直接覆盖写入磁盘
        let dir = Self.profileDirURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileUrl = dir.appendingPathComponent(name + ".conf")
        try? content.write(to: fileUrl, atomically: true, encoding: .utf8)
        // 如果是当前使用的 profile，同步到 default 并重连
        if status?.service == name {
            let defaultUrl = URL(fileURLWithPath: "\(NSHomeDirectory())/.local/share/wgsense/profiles/default.conf")
            try? content.write(to: defaultUrl, atomically: true, encoding: .utf8)
        }
    }
    // MARK: - Transfer 文件传输

    struct TransferDevice: Codable, Identifiable {
        let id: String          // "IP:Port" 格式
        let alias: String
        let ip: String?
        let port: Int?
        let deviceModel: String?
        let fingerprint: String?
        let deviceType: String?
        let version: String?
        let download: Bool
        let source: String?     // "multicast" | "scan" | "manual"
    }

    struct TransferReceiveState: Codable {
        let alias: String
        let downloads: String
        let port: Int
        let running: Bool
        let pending: [String]
    }

    @Published var transferDevices: [TransferDevice] = []
    @Published var transferState: TransferReceiveState?

    /// 发现局域网内设备（多播 + 手动合并）
    func fetchTransferDevices(timeoutSec: Int = 3) async {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/transfer/devices"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "timeout", value: "\(timeoutSec)")]
        guard let url = components.url else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let result = try? JSONDecoder().decode(TransferDevicesResponse.self, from: data) {
                transferDevices = result.devices
            }
        } catch { /* 网络错误或服务未启动 */ }
    }

    /// 单播扫描子网发现设备（用于 WG 隧道等无多播环境）
    func scanSubnet(timeoutSec: Int = 10, subnet: String? = nil) async -> [TransferDevice] {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/transfer/scan"), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "timeout", value: "\(timeoutSec)")]
        if let subnet, !subnet.isEmpty {
            items.append(URLQueryItem(name: "subnet", value: subnet))
        }
        components.queryItems = items
        guard let url = components.url else { return [] }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let result = try? JSONDecoder().decode(TransferDevicesResponse.self, from: data) {
                // 合并到现有列表（去重）
                let existingIDs = Set(transferDevices.map { $0.id })
                let newDevs = result.devices.filter { !existingIDs.contains($0.id) }
                transferDevices += newDevs
                return result.devices
            }
        } catch { /* 扫描失败 */ }
        return []
    }

    /// 手动添加设备（IP 或 IP:Port）
    func addManualDevice(addr: String) async -> TransferDevice? {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/transfer/add-device"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["addr": addr])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let device = try? JSONDecoder().decode(TransferDevice.self, from: data)
            if let device {
                // 加入设备列表
                if !transferDevices.contains(where: { $0.id == device.id }) {
                    transferDevices.append(device)
                }
            }
            return device
        } catch {
            alertMsg = "添加设备失败: \(error.localizedDescription)"
            return nil
        }
    }

    /// 移除手动添加的设备
    func removeManualDevice(deviceID: String) async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/transfer/remove-device"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["id": deviceID])
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if (resp as? HTTPURLResponse)?.statusCode == 200 {
                transferDevices.removeAll { $0.id == deviceID }
                return true
            }
        } catch { /* 忽略 */ }
        return false
    }

    struct TransferDevicesResponse: Codable {
        let devices: [TransferDevice]
    }

    /// 获取传输接收状态
    func fetchTransferState() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("api/transfer/receive"))
            transferState = try? JSONDecoder().decode(TransferReceiveState.self, from: data)
        } catch { /* 服务未启动 */ }
    }

    /// 发送文件到目标设备
    func sendFiles(to deviceID: String, paths: [String]) async -> Bool {
        let body: [String: Any] = ["id": deviceID, "paths": paths]
        var req = URLRequest(url: baseURL.appendingPathComponent("api/transfer/send"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 300
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch {
            alertMsg = "发送失败: \(error.localizedDescription)"
            return false
        }
    }

    /// 取消传输任务
    func cancelTransfer(taskID: String) async {
        let body: [String: String] = ["task_id": taskID]
        var req = URLRequest(url: baseURL.appendingPathComponent("api/transfer/cancel"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - 代理管理 (Mihomo)

    struct ProxyStatus: Codable {
        let running: Bool
        let address: String?
        let baseURL: String?
    }

    struct MihomoVersion: Codable {
        let meta: Bool
        let version: String
        let premium: Bool
        let foundation: Bool
    }

    struct ProxyInfo: Codable, Identifiable {
        var id: String { name }
        let name: String
        let type: String           // Selector/Fallback/URLTest/LoadBalance/PassThrough/Reject
        let all: [String]?         // 可选节点列表
        let now: String?           // 当前选中
        let alive: Bool?
        let udp: Bool?
        let xudp: Bool?
        let provider: String?
    }

    struct ProxiesResponse: Codable {
        let proxies: [String: ProxyInfo]
    }

    struct DelayResult: Codable {
        let delay: Int64?
        let message: String?
        let error: String?
    }

    struct ConnectionInfo: Codable, Identifiable {
        let id: String
        let metadata: ConnectionMetadata
        let upload: Int64
        let download: Int64
        let start: String?
        let chains: [String]?
        let rule: String?
        let uploadSpeed: Int64?
        let downloadSpeed: Int64?
        let alive: Bool?
    }

    struct ConnectionMetadata: Codable {
        let netWork: String?
        let type: String?
        let sourceIP: String?
        let sourcePort: String?
        let destinationIP: String?
        let destinationPort: String?
        let host: String?
        let process: String?
        let processPath: String?
        let remoteDestination: String?
    }

    struct ConnectionsResponse: Codable {
        let downloadTotal: Int64
        let uploadTotal: Int64
        let connections: [ConnectionInfo]
    }

    struct RuleInfo: Codable, Identifiable {
        var id: String { payload ?? UUID().uuidString }
        let type: String
        let payload: String?
        let proxy: String?
        let chains: [String]?
        let size: Int64?
    }

    struct RulesResponse: Codable {
        let rules: [RuleInfo]
    }

    struct MihomoConfig: Codable {
        let mode: String?
        let logLevel: String?
        let allowLan: Bool?
        let tunEnable: Bool?
        let mixedPort: Int?
    }

    @Published var proxyRunning: Bool = false
    @Published var proxyAddress: String = ""
    @Published var mihomoVersion: MihomoVersion?
    @Published var proxies: [String: ProxyInfo] = [:]
    @Published var connections: ConnectionsResponse?
    @Published var rules: [RuleInfo] = []
    @Published var mihomoConfig: MihomoConfig?

    /// 获取代理模块状态
    func fetchProxyStatus() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("api/proxy/status"))
            if let result = try? JSONDecoder().decode(ProxyStatus.self, from: data) {
                proxyRunning = result.running
                proxyAddress = result.address ?? ""
            }
        } catch { proxyRunning = false }
    }

    /// 获取 Mihomo 版本
    func fetchProxyVersion() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("api/proxy/version"))
            mihomoVersion = try? JSONDecoder().decode(MihomoVersion.self, from: data)
        } catch { mihomoVersion = nil }
    }

    /// 获取所有代理（策略组 + 节点）
    func fetchProxies() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("api/proxy/proxies"))
            if let result = try? JSONDecoder().decode(ProxiesResponse.self, from: data) {
                proxies = result.proxies
            }
        } catch { proxies = [:] }
    }

    /// 切换策略组选中节点
    func selectProxy(group: String, name: String) async -> Bool {
        let body: [String: String] = ["group": group, "name": name]
        var req = URLRequest(url: baseURL.appendingPathComponent("api/proxy/select"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    /// 测试单个节点延迟
    func testDelay(name: String) async -> DelayResult? {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/proxy/delay"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let url = components.url else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try? JSONDecoder().decode(DelayResult.self, from: data)
        } catch { return nil }
    }

    /// 测试整个策略组延迟
    func testGroupDelay(group: String) async -> DelayResult? {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/proxy/delay"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "group", value: group)]
        guard let url = components.url else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try? JSONDecoder().decode(DelayResult.self, from: data)
        } catch { return nil }
    }

    /// 获取活跃连接快照
    func fetchConnections() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("api/proxy/connections"))
            connections = try? JSONDecoder().decode(ConnectionsResponse.self, from: data)
        } catch { connections = nil }
    }

    /// 关闭指定连接
    func closeConnection(id: String) async -> Bool {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/proxy/connection-close"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        guard let url = components.url else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    /// 关闭全部连接
    func closeAllConnections() async -> Bool {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/proxy/connections-close-all"))
        req.httpMethod = "POST"
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    /// 获取规则列表
    func fetchRules() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("api/proxy/rules"))
            if let result = try? JSONDecoder().decode(RulesResponse.self, from: data) {
                rules = result.rules
            }
        } catch { rules = [] }
    }

    /// 获取 Mihomo 运行配置
    func fetchProxyConfig() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("api/proxy/configs"))
            mihomoConfig = try? JSONDecoder().decode(MihomoConfig.self, from: data)
        } catch { mihomoConfig = nil }
    }

    /// 更新订阅
    func updateProvider(name: String) async -> Bool {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/proxy/provider-update"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let url = components.url else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    /// 清除 FakeIP 缓存
    func flushFakeIP() async -> Bool {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/proxy/cache"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "action", value: "fakeip")]
        guard let url = components.url else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }
}

struct ExportResponse: Codable {
    let name: String
    let content: String
}
