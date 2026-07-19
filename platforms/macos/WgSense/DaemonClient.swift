import SwiftUI

@MainActor
class DaemonClient: ObservableObject {
    struct LogLine: Identifiable, Equatable {
        let id: UUID
        let text: String

        init(id: UUID = UUID(), text: String) {
            self.id = id
            self.text = text
        }
    }

    @Published var status: DaemonStatus?
    @Published var profiles: [String] = []
    @Published var errorMsg: String?
    @Published var alertMsg: String?
    @Published var logLines: [LogLine] = []
    @Published var traffic: TrafficStats?
    @Published private(set) var isAuthorizingDaemon = false
    @Published private(set) var pendingConnected: Bool?
    @Published private(set) var pendingGuardRunning: Bool?
    @Published private(set) var pendingPaused: Bool?
    private var lastAuthorizationFailure: Date?

    /// 暂停时长（分钟），可在设置页修改，默认 5
    @AppStorage("pauseMinutes") var pauseMinutes: Int = 5

    // 运行配置（AppStorage 本地缓存 + 同步到 daemon）
    @AppStorage("healthCheckTarget") var healthCheckTarget: String = "https://1.1.1.1"
    @AppStorage("intervalSeconds") var intervalSeconds: Int = 10
    @AppStorage("autoUpGraceSeconds") var autoUpGraceSeconds: Int = 20
    @AppStorage("trustedNetworkPrefixes") var trustedNetworkPrefixes: String = ""
    @AppStorage("autoConnectUntrusted") var autoConnectUntrusted: Bool = true
    @AppStorage("guardAutomationEnabled") private var guardAutomationEnabled: Bool = false

    private let api = DaemonAPIClient()
    private let controlAPI = DaemonControlAPIClient()
    private let profileStore = ProfileFileStore()
    private let transferAPI = TransferAPIClient()
    private let proxyAPI = ProxyAPIClient()
    private var baseURL: URL { api.baseURL }
    private var pollTimer: Timer?

    /// Daemon 二进制路径（需 sudo 启动）。Release/Debug 优先使用 App bundle 内嵌 helper。
    private static var daemonPath: String {
        if let bundled = Bundle.main.path(forResource: "wgsense-daemon", ofType: nil, inDirectory: "libexec") {
            return bundled
        }
        return "/usr/local/libexec/wgsense-daemon"
    }

    init() {
        migrateTrustedNetworkPolicyIfNeeded()
        startPolling()
    }

    private func migrateTrustedNetworkPolicyIfNeeded() {
        let defaults = UserDefaults.standard
        let migrationKey = "trustedNetworkPolicyV2Migrated"
        guard !defaults.bool(forKey: migrationKey) else { return }

        // Earlier builds persisted `false` as a product default even though the
        // guard tile implied full trusted/untrusted automation.
        autoConnectUntrusted = true
        defaults.set(true, forKey: migrationKey)
    }

    var isVPNOn: Bool {
        pendingConnected ?? (status?.state == "Connected")
    }

    var isGuardOn: Bool {
        pendingGuardRunning ?? (status.map { !$0.paused } ?? false)
    }

    var isPauseOn: Bool {
        pendingPaused ?? (status?.paused ?? false)
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

    /// 确保 daemon 在线：先快速检测，不可达则自动弹出授权窗口启动 daemon（root）
    func ensureDaemon(requireActive: Bool = false, authorizeIfNeeded: Bool = false) async -> Bool {
        // 异步快速检测（不阻塞 UI）
        let runningStatus = try? await controlAPI.status(timeout: 1.0)

        if let runningStatus, !requireActive || runningStatus.passive != true {
            await syncConfigSilently()
            return true
        }
        if runningStatus?.passive == true {
            alertMsg = "当前是被动服务，无法建立 WireGuard；请启动正式网络服务"
            return false
        }

        guard authorizeIfNeeded else {
            errorMsg = "daemon 未连接"
            return false
        }
        if let lastAuthorizationFailure, Date().timeIntervalSince(lastAuthorizationFailure) < 8 {
            errorMsg = "daemon 未启动；稍后再试"
            return false
        }
        guard !isAuthorizingDaemon else {
            errorMsg = "正在等待管理员授权..."
            return false
        }
        isAuthorizingDaemon = true
        defer { isAuthorizingDaemon = false }
        errorMsg = "需要管理员授权以启动网络服务"

        // Daemon 不可达 → 尝试通过 osascript + administrator privileges 启动（弹出 macOS 授权窗口）
        let started = await startDaemonWithPrivileges()
        if started {
            // 等待 daemon 就绪
            try? await Task.sleep(for: .seconds(2))
            let retryReachable = (try? await controlAPI.status(timeout: 2.0)) != nil
            if retryReachable {
                await syncConfigSilently()
                markDaemonUp()
                return true
            }
        }

        lastAuthorizationFailure = Date()
        errorMsg = "Daemon 未启动；可再次点击 VPN 重试授权"
        return false
    }

    /// 通过 osascript 弹出系统授权窗口，以 root 权限启动 daemon
    private func startDaemonWithPrivileges() async -> Bool {
        let daemonPath = Self.daemonPath
        let runtimePath = NSHomeDirectory() + "/.local/share/wgsense"
        let downloadPath = NSHomeDirectory() + "/.local/share/wgsense/incoming"
        let autoConnect = autoConnectUntrusted ? "true" : "false"
        let startPaused = guardAutomationEnabled ? "false" : "true"
        let trustedPrefixes = trustedNetworkPrefixes
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let daemon = daemonPath.replacingOccurrences(of: "'", with: "'\\''")
                let runtime = runtimePath.replacingOccurrences(of: "'", with: "'\\''")
                let downloads = downloadPath.replacingOccurrences(of: "'", with: "'\\''")
                let prefixes = trustedPrefixes.replacingOccurrences(of: "'", with: "'\\''")
                let shellCmd = "'\(daemon)' --api 127.0.0.1:8765 --runtime-dir '\(runtime)' --download-dir '\(downloads)' --trusted-network-prefixes '\(prefixes)' --auto-connect-untrusted=\(autoConnect) --start-paused=\(startPaused) --app-owned=true </dev/null >>/var/log/wgsense-daemon.log 2>&1 &"
                let escaped = shellCmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                let script = "do shell script \"\(escaped)\" with administrator privileges"

                let task = Process()
                task.launchPath = "/usr/bin/osascript"
                task.arguments = ["-e", script]
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = pipe

                do {
                    try task.run()
                    task.waitUntilExit()
                    let success = (task.terminationStatus == 0)
                    if !success {
                        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        print("[DaemonClient] daemon 启动失败: \(output)")
                    }
                    continuation.resume(returning: success)
                } catch {
                    print("[DaemonClient] osascript 异常: \(error.localizedDescription)")
                    continuation.resume(returning: false)
                }
            }
        }
    }

    private func log(_ msg: String) {
        print("[DaemonClient] \(msg)")
    }

    /// 重置可达状态（供轮询成功后调用）
    func markDaemonUp() {
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
                if self.status != nil { await self.fetchTransferState() }
                // 每 3 次轮询拉一次流量（约 6 秒间隔）
                tick += 1
                if tick % 3 == 0 { await self.fetchTraffic() }
            }
        }
        // 立即拉一次
        Task {
            await fetchStatus()
            if status != nil { await fetchTransferState() }
            await fetchTraffic()
        }
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
            status = try await controlAPI.status()
            guardAutomationEnabled = !(status?.paused ?? true)
            markDaemonUp()
        } catch {
            status = nil
            transferState = nil
            errorMsg = "daemon 未连接"
        }
    }

    func fetchProfiles() async {
        do {
            profiles = try await controlAPI.profiles()
        } catch {
            // daemon 离线时从文件系统直读
            profiles = profileStore.listProfiles()
        }
    }

    /// 拉取最近 N 行日志（供小磁贴日志滚动用）
    func fetchLogs(n: Int = 15) async {
        do {
            let incoming = try await controlAPI.logs(limit: n).lines
            mergeLogLines(incoming, limit: max(n, 500))
        } catch { /* daemon 可能还没启动 */ }
    }

    private func mergeLogLines(_ incoming: [String], limit: Int) {
        guard !incoming.isEmpty else { return }
        let current = logLines.map(\.text)
        if current.suffix(incoming.count).elementsEqual(incoming) { return }

        let maxOverlap = min(current.count, incoming.count)
        var overlap = 0
        if maxOverlap > 0 {
            for count in stride(from: maxOverlap, through: 1, by: -1) {
                if current.suffix(count).elementsEqual(incoming.prefix(count)) {
                    overlap = count
                    break
                }
            }
        }

        if overlap == 0 && !current.isEmpty {
            logLines = incoming.map { LogLine(text: $0) }
        } else {
            logLines.append(contentsOf: incoming.dropFirst(overlap).map { LogLine(text: $0) })
        }
        if logLines.count > limit {
            logLines.removeFirst(logLines.count - limit)
        }
    }

    /// 拉取实时流量统计
    func fetchTraffic() async {
        do {
            traffic = try await controlAPI.traffic()
        } catch { traffic = nil }
    }

    func post(_ endpoint: String) async {
        await dispatchDaemonCommand(endpoint)
    }

    /// 守护开关代表完整网络策略：受信任网络断开，非受信任网络自动连接。
    func setGuardEnabled(_ enabled: Bool) async {
        guardAutomationEnabled = enabled
        if enabled {
            autoConnectUntrusted = true
            guard await ensureDaemon(requireActive: true, authorizeIfNeeded: true) else { return }
            await syncConfigSilently()
            await runDaemonCommand("resume")
        } else {
            await runDaemonCommand("pause")
        }
    }

    static func shutdownAppOwnedDaemonSync() {
        guard let url = URL(string: "http://127.0.0.1:8765/api/shutdown") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 1.0
        let sem = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: req) { _, _, _ in sem.signal() }
        task.resume()
        _ = sem.wait(timeout: .now() + 1.2)
    }

    func shutdownAppOwnedDaemon() async -> Bool {
        do {
            try await controlAPI.shutdownAppOwnedDaemon()
            status = nil
            errorMsg = "daemon 已关闭"
            return true
        } catch {
            alertMsg = "关闭 daemon 失败: \(error.localizedDescription)"
            return false
        }
    }

    /// 发送 POST 并等待完成（用于需要严格顺序的操作）
    func postAndWait(_ endpoint: String) async {
        await dispatchDaemonCommand(endpoint)
    }

    private func dispatchDaemonCommand(_ endpoint: String) async {
        if endpoint == "connect" {
            await connectVPN()
            return
        }
        await runDaemonCommand(endpoint)
    }

    private func connectVPN() async {
        setPending(connect: true, guardRunning: nil, paused: nil)
        guard await ensureDaemon(requireActive: true, authorizeIfNeeded: true) else {
            clearPendingState()
            return
        }

        let oldStatus = status
        do {
            let current = try await controlAPI.status(timeout: 2)
            status = current

            optimisticUpdate("connect")
            // Connect waits for endpoint resolution and WireGuard handshake. Keep this
            // longer than the daemon's handshake window so the UI receives the real error.
            try await controlAPI.command("connect", timeout: 30)
            markDaemonUp()
            await fetchStatus()
            clearPendingState()
        } catch {
            let message = DaemonAPIClient.connectionMessage(error) == "daemon 未连接"
                ? "无法连接 daemon"
                : "连接失败：\(error.localizedDescription)"
            revertAndAlert(oldStatus, message)
            await fetchStatus()
            clearPendingState()
        }
    }

    private func runDaemonCommand(_ endpoint: String) async {
        let shouldStartDaemon = endpoint == "connect" || endpoint == "resume"
        setPending(for: endpoint)
        guard await ensureDaemon(requireActive: endpoint == "connect", authorizeIfNeeded: shouldStartDaemon) else {
            clearPendingState()
            return
        }

        let oldStatus = status
        optimisticUpdate(endpoint)
        do {
            try await controlAPI.command(endpoint)
            markDaemonUp()
            await fetchStatus()
            clearPendingState()
        } catch {
            let message = DaemonAPIClient.connectionMessage(error) == "daemon 未连接"
                ? "无法连接 daemon"
                : "操作失败：\(error.localizedDescription)"
            revertAndAlert(oldStatus, message)
            clearPendingState()
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

    private func setPending(for endpoint: String) {
        switch endpoint {
        case "connect":
            setPending(connect: true, guardRunning: nil, paused: nil)
        case "disconnect":
            setPending(connect: false, guardRunning: nil, paused: nil)
        case "pause":
            setPending(connect: nil, guardRunning: false, paused: true)
        case "resume":
            setPending(connect: nil, guardRunning: true, paused: false)
        default:
            break
        }
    }

    private func setPending(connect: Bool?, guardRunning: Bool?, paused: Bool?) {
        withAnimation(.smooth(duration: 0.22, extraBounce: 0.08)) {
            if let connect { pendingConnected = connect }
            if let guardRunning { pendingGuardRunning = guardRunning }
            if let paused { pendingPaused = paused }
        }
    }

    private func clearPendingState() {
        withAnimation(.smooth(duration: 0.22, extraBounce: 0.05)) {
            pendingConnected = nil
            pendingGuardRunning = nil
            pendingPaused = nil
        }
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
            try profileStore.saveProfile(name, content: content)
        } catch { /* 继续尝试 daemon */ }
        // 2. 再通知 daemon（如果在线）
        try? await controlAPI.importProfile(name: name, content: content)
    }

    /// 导出 profile 内容（先读磁盘，daemon 作为备选）
    func exportProfile(name: String) async -> String {
        // 优先从本地文件读取
        if let content = profileStore.readProfile(name) {
            return content
        }
        // daemon 备选
        do {
            return try await controlAPI.exportProfile(name: name).content
        } catch { return "" }
    }

    /// 加载 profile 内容供编辑（直接读磁盘）
    func loadProfileContent(name: String) async -> String {
        profileStore.readProfile(name) ?? ""
    }

    /// 切换当前使用的 profile（复制为 default.conf → 重连）
    func switchProfile(_ name: String) async {
        // 1. 读取目标 profile 内容
        guard let content = profileStore.readProfile(name) else {
            alertMsg = "无法读取配置「\(name)」"
            return
        }

        // 2. 写到 default.conf（ daemon 的默认配置路径）
        do {
            try profileStore.saveDefault(content: content)
        } catch {
            alertMsg = "切换配置失败：\(error.localizedDescription)"
            return
        }

        // 3. 断开再连接（让 daemon 用新配置）
        await postAndWait("disconnect")
        try? await Task.sleep(for: .milliseconds(300))
        await postAndWait("connect")
        await fetchStatus()
    }

    func saveProfile(_ profile: WGProfile) async {
        // 1. 先直接写 .conf 文件
        do {
            try profileStore.saveProfile(profile.name, content: profile.wireGuardConfig)
        } catch {
            alertMsg = "保存配置失败：\(error.localizedDescription)"
            return
        }
        // 2. 再通知 daemon
        do {
            try await controlAPI.saveProfile(profile)
            await fetchProfiles()
        } catch {
            alertMsg = "配置已保存到本机，但同步 daemon 失败：\(error.localizedDescription)"
        }
    }

    func deleteProfile(name: String) async {
        // 1. 先直接删文件
        do {
            try profileStore.deleteProfile(name)
        } catch {
            alertMsg = "删除配置失败：\(error.localizedDescription)"
            return
        }
        // 2. 再通知 daemon
        do {
            try await controlAPI.deleteProfile(name: name)
            await fetchProfiles()
        } catch {
            alertMsg = "配置已从本机删除，但同步 daemon 失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 配置同步

    func syncConfig() async -> Bool {
        let prefixes = trustedNetworkPrefixes
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        do {
            try await controlAPI.syncConfig(
                trustedNetworkPrefixes: prefixes,
                autoConnectUntrusted: autoConnectUntrusted,
                intervalSeconds: intervalSeconds,
                autoUpGraceSeconds: autoUpGraceSeconds,
                healthCheckTarget: healthCheckTarget
            )
            alertMsg = "配置已应用到 daemon"
            return true
        } catch {
            alertMsg = "配置应用失败: \(error.localizedDescription)"
            return false
        }
    }

    private func syncConfigSilently() async {
        let prefixes = trustedNetworkPrefixes
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        try? await controlAPI.syncConfig(
            trustedNetworkPrefixes: prefixes,
            autoConnectUntrusted: autoConnectUntrusted,
            intervalSeconds: intervalSeconds,
            autoUpGraceSeconds: autoUpGraceSeconds,
            healthCheckTarget: healthCheckTarget
        )
    }

    // MARK: - Profile 切换

    /// 更新 profile 内容（写磁盘 + 同步 default）
    func updateProfile(name: String, content: String) async {
        // 直接覆盖写入磁盘
        do {
            try profileStore.saveProfile(name, content: content)
        } catch {
            alertMsg = "更新配置失败：\(error.localizedDescription)"
            return
        }
        // 如果是当前使用的 profile，同步到 default 并重连
        if status?.service == name {
            do {
                try profileStore.saveDefault(content: content)
            } catch {
                alertMsg = "配置已更新，但应用到当前连接失败：\(error.localizedDescription)"
            }
        }
    }
    // MARK: - Transfer 文件传输

    typealias TransferDevice = WgSense.TransferDevice
    typealias TransferReceiveState = WgSense.TransferReceiveState
    typealias TransferFileProgress = WgSense.TransferFileProgress
    typealias TransferSendFileProgress = WgSense.TransferSendFileProgress
    typealias TransferSendTask = WgSense.TransferSendTask
    typealias TransferSendTasksState = WgSense.TransferSendTasksState
    typealias TransferPendingFile = WgSense.TransferPendingFile
    typealias TransferPendingRequest = WgSense.TransferPendingRequest

    @Published var transferDevices: [TransferDevice] = []
    @Published var transferState: TransferReceiveState?
	@Published var transferSendTasks: TransferSendTasksState?
	@Published var transferError: String?

    /// 发现局域网内设备（多播 + 手动合并）
    func fetchTransferDevices(timeoutSec: Int = 3) async {
        do {
            transferDevices = try await transferAPI.devices(timeoutSec: timeoutSec)
            transferError = nil
        } catch {
            transferError = daemonConnectionMessage(error)
        }
    }

    /// 单播扫描子网发现设备（用于 WG 隧道等无多播环境）
    func scanSubnet(timeoutSec: Int = 10, subnet: String? = nil) async -> [TransferDevice] {
        do {
            let devices = try await transferAPI.scan(timeoutSec: timeoutSec, subnet: subnet)
            let existingIDs = Set(transferDevices.map { $0.id })
            transferDevices += devices.filter { !existingIDs.contains($0.id) }
            return devices
        } catch {
            alertMsg = "扫描失败: \(error.localizedDescription)"
            return []
        }
    }

    /// 手动添加设备（IP 或 IP:Port）
    func addManualDevice(addr: String) async -> TransferDevice? {
        do {
            let device = try await transferAPI.addManualDevice(addr: addr)
            if !transferDevices.contains(where: { $0.id == device.id }) {
                transferDevices.append(device)
            }
            return device
        } catch {
            alertMsg = "添加设备失败: \(error.localizedDescription)"
            return nil
        }
    }

    /// 移除手动添加的设备
    func removeManualDevice(deviceID: String) async -> Bool {
        do {
            let result = try await transferAPI.removeManualDevice(deviceID: deviceID)
            if result {
                transferDevices.removeAll { $0.id == deviceID }
            }
            return result
        } catch { /* 忽略 */ }
        return false
    }

    /// 获取传输接收状态
    func fetchTransferState() async {
        do {
            transferState = try await transferAPI.receiveState()
            transferError = nil
        } catch {
            transferState = nil
            transferError = daemonConnectionMessage(error)
        }
    }

    /// 启停传输接收服务
    func setTransferReceiveEnabled(_ enabled: Bool) async -> Bool {
        do {
            transferState = try await transferAPI.setReceiveEnabled(enabled)
            return true
        } catch {
            alertMsg = "\(enabled ? "启动" : "停止")接收服务失败: \(error.localizedDescription)"
            return false
        }
    }

    /// 接受或拒绝一个等待中的官方 LocalSend 上传请求。
    func resolveTransferRequest(_ requestID: String, accepted: Bool) async -> Bool {
        do {
            try await transferAPI.resolveRequest(requestID, accepted: accepted)
            await fetchTransferState()
            return true
        } catch {
            alertMsg = "处理接收请求失败: \(error.localizedDescription)"
            return false
        }
    }

    /// 创建后台发送任务，后续进度从 /api/transfer/tasks 获取。
    func startFileSend(to deviceID: String, paths: [String]) async -> TransferSendTask? {
        do {
            let task = try await transferAPI.startSend(to: deviceID, paths: paths)
            await fetchTransferTasks()
            return task
        } catch {
            alertMsg = "发送失败: \(error.localizedDescription)"
            return nil
        }
    }

    func fetchTransferTasks() async {
        do {
            transferSendTasks = try await transferAPI.tasks()
            transferError = nil
        } catch {
            transferError = daemonConnectionMessage(error)
        }
    }

	private func daemonConnectionMessage(_ error: Error) -> String {
		DaemonAPIClient.connectionMessage(error)
	}

    /// 取消传输任务
    func cancelTransfer(taskID: String) async -> Bool {
        do {
            try await transferAPI.cancel(taskID: taskID)
            await fetchTransferTasks()
            return true
        } catch {
            alertMsg = "取消发送失败: \(error.localizedDescription)"
            return false
        }
    }

    /// 启动文件传输所需的应用自有后台服务，不连接 WireGuard。
    func startDaemonForTransfer() async -> Bool {
        let ok = await ensureDaemon(requireActive: false, authorizeIfNeeded: true)
        guard ok else {
            transferError = errorMsg ?? "后台服务启动失败"
            return false
        }
        await fetchTransferState()
        await fetchTransferDevices(timeoutSec: 2)
        await fetchTransferTasks()
        return true
    }

    // MARK: - 代理管理 (Mihomo)

    typealias ProxyStatus = WgSense.ProxyStatus
    typealias ProxySettings = WgSense.ProxySettings
    typealias ProxySettingsResponse = WgSense.ProxySettingsResponse
    typealias MihomoVersion = WgSense.MihomoVersion
    typealias DelayHistory = WgSense.DelayHistory
    typealias ProxyInfo = WgSense.ProxyInfo
    typealias ProxiesResponse = WgSense.ProxiesResponse
    typealias DelayResult = WgSense.DelayResult
    typealias GroupDelayResult = WgSense.GroupDelayResult
    typealias ConnectionInfo = WgSense.ConnectionInfo
    typealias ConnectionMetadata = WgSense.ConnectionMetadata
    typealias ConnectionsResponse = WgSense.ConnectionsResponse
    typealias RuleInfo = WgSense.RuleInfo
    typealias RulesResponse = WgSense.RulesResponse
    typealias ProxyProviderInfo = WgSense.ProxyProviderInfo
    typealias SubscriptionInfo = WgSense.SubscriptionInfo
    typealias ProxyProvidersResponse = WgSense.ProxyProvidersResponse
    typealias RuleProviderInfo = WgSense.RuleProviderInfo
    typealias RuleProvidersResponse = WgSense.RuleProvidersResponse
    typealias MihomoConfig = WgSense.MihomoConfig
    typealias DNSQueryResponse = WgSense.DNSQueryResponse
    typealias ProxyLogEntry = WgSense.ProxyLogEntry
    typealias ProxyLogsResponse = WgSense.ProxyLogsResponse

    @Published var proxyRunning: Bool = false
    @Published var proxyServiceRunning: Bool = false
    @Published var proxyAddress: String = ""
    @Published var proxyStatus: ProxyStatus?
    @Published var proxySettings: ProxySettings?
    @Published var proxyError: String?
    @Published var proxyNotice: String?
    @Published var mihomoVersion: MihomoVersion?
    @Published var proxies: [String: ProxyInfo] = [:]
    @Published var connections: ConnectionsResponse?
    @Published var rules: [RuleInfo] = []
    @Published var proxyProviders: [String: ProxyProviderInfo] = [:]
    @Published var ruleProviders: [String: RuleProviderInfo] = [:]
    @Published var mihomoConfig: MihomoConfig?
    @Published var dnsQueryResult: DNSQueryResponse?
    @Published var proxyLogs: [ProxyLogEntry] = []

    private func proxyFailure(_ error: Error, prefix: String? = nil) {
        let message = error.localizedDescription
        proxyError = prefix.map { "\($0): \(message)" } ?? message
        proxyNotice = nil
    }

    private func runProxyCommand(
        _ command: () async throws -> Void,
        success: String? = nil
    ) async -> Bool {
        do {
            try await command()
            proxyError = nil
            proxyNotice = success
            return true
        } catch {
            proxyFailure(error)
            return false
        }
    }

    func fetchProxyStatus() async {
        do {
            let result = try await proxyAPI.status()
            proxyStatus = result
            proxyServiceRunning = result.running
            proxyRunning = result.connected
            proxyAddress = result.address
            proxyError = result.connected ? nil : result.lastError
        } catch {
            proxyStatus = nil
            proxyServiceRunning = false
            proxyRunning = false
            proxyFailure(error, prefix: "读取代理状态失败")
        }
    }

    func startDaemonForProxy() async -> Bool {
        let ok = await ensureDaemon(requireActive: false, authorizeIfNeeded: true)
        await fetchProxySettings()
        await fetchProxyStatus()
        if ok {
            proxyNotice = proxyRunning ? "后台服务已启动，控制器连接成功" : "后台服务已启动，请检查控制器地址与密钥"
        } else {
            proxyError = errorMsg ?? "后台服务启动失败"
        }
        return ok
    }

    func fetchProxySettings() async {
        do {
            let result = try await proxyAPI.settings()
            proxySettings = result.settings
            proxyStatus = result.status
            proxyAddress = result.settings.address
            proxyServiceRunning = result.status.running
            proxyRunning = result.status.connected
            proxyError = result.status.connected ? nil : result.status.lastError
        } catch {
            proxyFailure(error, prefix: "读取控制器设置失败")
        }
    }

    func saveProxySettings(
        address: String,
        secret: String?,
        latencyTestURL: String,
        latencyTimeout: Int,
        latencyLow: Int,
        latencyMedium: Int
    ) async -> Bool {
        do {
            let result = try await proxyAPI.saveSettings(
                address: address,
                secret: secret,
                latencyTestURL: latencyTestURL,
                latencyTimeout: latencyTimeout,
                latencyLow: latencyLow,
                latencyMedium: latencyMedium
            )
            proxySettings = result.settings
            proxyStatus = result.status
            proxyAddress = result.settings.address
            proxyServiceRunning = result.status.running
            proxyRunning = result.status.connected
            proxyError = result.status.connected ? nil : result.status.lastError
            proxyNotice = result.status.connected ? "控制器连接成功" : "设置已保存，连接测试失败"
            return result.status.connected
        } catch {
            proxyFailure(error, prefix: "保存控制器设置失败")
            return false
        }
    }

    func fetchProxyVersion() async {
        do {
            mihomoVersion = try await proxyAPI.version()
        } catch {
            mihomoVersion = nil
            proxyFailure(error, prefix: "读取核心版本失败")
        }
    }

    func fetchProxies() async {
        do {
            let result = try await proxyAPI.proxies()
            proxies = result.proxies
            proxyError = nil
        } catch {
            proxyFailure(error, prefix: "读取代理节点失败")
        }
    }

    func selectProxy(group: String, name: String) async -> Bool {
        let ok = await runProxyCommand(
            { try await proxyAPI.selectProxy(group: group, name: name) },
            success: "已切换到 \(name)"
        )
        if ok { await fetchProxies() }
        return ok
    }

    func testDelay(name: String) async -> DelayResult? {
        do {
            return try await proxyAPI.delay(name: name)
        } catch {
            proxyFailure(error, prefix: "延迟测试失败")
            return nil
        }
    }

    func testGroupDelay(group: String) async -> GroupDelayResult? {
        do {
            return try await proxyAPI.groupDelay(group: group)
        } catch {
            proxyFailure(error, prefix: "策略组延迟测试失败")
            return nil
        }
    }

    func fetchConnections() async {
        do {
            connections = try await proxyAPI.connections()
        } catch {
            proxyFailure(error, prefix: "读取连接失败")
        }
    }

    func closeConnection(id: String) async -> Bool {
        let ok = await runProxyCommand { try await proxyAPI.closeConnection(id: id) }
        if ok { await fetchConnections() }
        return ok
    }

    func closeAllConnections() async -> Bool {
        let ok = await runProxyCommand(
            { try await proxyAPI.closeAllConnections() },
            success: "已关闭全部连接"
        )
        if ok { await fetchConnections() }
        return ok
    }

    func fetchRules() async {
        do {
            let result = try await proxyAPI.rules()
            rules = result.rules
        } catch {
            proxyFailure(error, prefix: "读取规则失败")
        }
    }

    func fetchProxyProviders() async {
        do {
            let result = try await proxyAPI.proxyProviders()
            proxyProviders = result.providers
        } catch {
            proxyFailure(error, prefix: "读取订阅失败")
        }
    }

    func fetchRuleProviders() async {
        do {
            let result = try await proxyAPI.ruleProviders()
            ruleProviders = result.providers
        } catch {
            proxyFailure(error, prefix: "读取规则集失败")
        }
    }

    func fetchProxyConfig() async {
        do {
            mihomoConfig = try await proxyAPI.config()
        } catch {
            proxyFailure(error, prefix: "读取运行配置失败")
        }
    }

    func updateProvider(name: String) async -> Bool {
        let ok = await runProxyCommand(
            { try await proxyAPI.updateProvider(name: name) },
            success: "订阅 \(name) 已更新"
        )
        if ok { await fetchProxyProviders(); await fetchProxies() }
        return ok
    }

    func healthCheckProvider(name: String) async -> Bool {
        await runProxyCommand(
            { try await proxyAPI.healthCheckProvider(name: name) },
            success: "订阅 \(name) 延迟测试完成"
        )
    }

    func updateRuleProvider(name: String) async -> Bool {
        let ok = await runProxyCommand(
            { try await proxyAPI.updateRuleProvider(name: name) },
            success: "规则集 \(name) 已更新"
        )
        if ok { await fetchRuleProviders(); await fetchRules() }
        return ok
    }

    func patchProxyConfig(_ values: [String: Any], success: String? = nil) async -> Bool {
        let ok = await runProxyCommand(
            { try await proxyAPI.patchConfig(values) },
            success: success
        )
        if ok { await fetchProxyConfig() }
        return ok
    }

    func updateProxyMode(_ mode: String) async -> Bool {
        await patchProxyConfig(["mode": mode], success: "运行模式已切换为 \(mode.uppercased())")
    }

    func updateProxyTUN(_ enabled: Bool) async -> Bool {
        await patchProxyConfig(["tun": ["enable": enabled]], success: enabled ? "TUN 已启用" : "TUN 已停用")
    }

    func updateProxyAllowLAN(_ enabled: Bool) async -> Bool {
        await patchProxyConfig(["allow-lan": enabled], success: enabled ? "局域网访问已允许" : "局域网访问已关闭")
    }

    func performProxyAction(_ action: String, success: String) async -> Bool {
        await runProxyCommand(
            { try await proxyAPI.performAction(action) },
            success: success
        )
    }

    func flushFakeIP() async -> Bool {
        await performProxyAction("flush-fakeip", success: "FakeIP 缓存已清除")
    }

    func queryProxyDNS(name: String, type: String) async -> Bool {
        do {
            dnsQueryResult = try await proxyAPI.dnsQuery(name: name, type: type)
            proxyError = nil
            return true
        } catch {
            dnsQueryResult = nil
            proxyFailure(error, prefix: "DNS 查询失败")
            return false
        }
    }

    func fetchProxyLogs(limit: Int = 200) async {
        do {
            let result = try await proxyAPI.logs(limit: limit)
            if proxyLogs.map(\.id) != result.logs.map(\.id) {
                proxyLogs = result.logs
            }
        } catch {
            proxyFailure(error, prefix: "读取 Mihomo 日志失败")
        }
    }
}
