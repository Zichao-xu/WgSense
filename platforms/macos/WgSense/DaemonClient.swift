import SwiftUI

struct DaemonStatus: Codable {
    var at_home: Bool
    var state: String
    var paused: Bool
    var service: String
}

@MainActor
class DaemonClient: ObservableObject {
    @Published var status: DaemonStatus?
    @Published var profiles: [String] = []
    @Published var errorMsg: String?
    @Published var alertMsg: String?

    /// 暂停时长（分钟），可在设置页修改，默认 5
    @AppStorage("pauseMinutes") var pauseMinutes: Int = 5

    // 运行配置（AppStorage 本地缓存 + 同步到 daemon）
    @AppStorage("healthCheckTarget") var healthCheckTarget: String = "https://1.1.1.1"
    @AppStorage("intervalSeconds") var intervalSeconds: Int = 10
    @AppStorage("autoUpGraceSeconds") var autoUpGraceSeconds: Int = 20
    @AppStorage("homeNetworkPrefixes") var homeNetworkPrefixes: String = "10.10.1."

    private let baseURL = URL(string: "http://127.0.0.1:8765")!
    private var pollTimer: Timer?

    init() {
        startPolling()
    }

    deinit {
        pollTimer?.invalidate()
    }

    /// 启动定时轮询，确保菜单栏图标状态始终最新
    func startPolling(interval: TimeInterval = 2.0) {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in
                await self.fetchStatus()
            }
        }
        // 立即拉一次
        Task { await fetchStatus() }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func refresh() async {
        await fetchStatus()
        await fetchProfiles()
    }

    func fetchStatus() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("api/status"))
            status = try JSONDecoder().decode(DaemonStatus.self, from: data)
            errorMsg = nil
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
            profiles = []
        }
    }

    func post(_ endpoint: String) async {
        // 保存旧状态用于失败回退
        let oldStatus = status

        // 乐观更新：立即反映状态变化
        optimisticUpdate(endpoint)

        var req = URLRequest(url: baseURL.appendingPathComponent("api/\(endpoint)"))
        req.httpMethod = "POST"
        req.timeoutInterval = 15.0

        // 后台发送请求
        Task {
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    await fetchStatus()
                } else {
                    // 服务器返回错误
                    await revertAndAlert(oldStatus, "操作失败：\(endpoint)")
                }
            } catch {
                // 网络错误/超时
                await revertAndAlert(oldStatus, "无法连接 daemon：\(error.localizedDescription)")
            }
        }
    }

    /// 发送 POST 并等待完成（用于需要严格顺序的操作）
    func postAndWait(_ endpoint: String) async {
        let oldStatus = status
        optimisticUpdate(endpoint)
        var req = URLRequest(url: baseURL.appendingPathComponent("api/\(endpoint)"))
        req.httpMethod = "POST"
        req.timeoutInterval = 15.0
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                await fetchStatus()
            } else {
                await revertAndAlert(oldStatus, "操作失败：\(endpoint)")
            }
        } catch {
            await revertAndAlert(oldStatus, "无法连接 daemon：\(error.localizedDescription)")
        }
    }

    /// 回退状态并弹窗提示
    @MainActor
    private func revertAndAlert(_ oldStatus: DaemonStatus?, _ msg: String) {
        status = oldStatus
        alertMsg = msg
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
        let body: [String: String] = ["name": name, "content": content]
        var req = URLRequest(url: baseURL.appendingPathComponent("api/profile/import"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }

    func exportProfile(name: String) async -> String {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/profile/export"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let url = components.url else { return "" }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let result = try JSONDecoder().decode(ExportResponse.self, from: data)
            return result.content
        } catch {
            return ""
        }
    }

    func saveProfile(_ profile: WGProfile) async {
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

    func switchProfile(_ name: String) async {
        // 先断开当前，再设置新 profile 并连接
        await post("disconnect")
        // 设置 service 需要通过 API（暂时用 connect 直接连，daemon 会用 default）
        // TODO: 需要 /api/profile/select 端点设置当前 profile
        await post("connect")
        await fetchStatus()
    }

    func loadProfileContent(name: String) async -> String {
        return await exportProfile(name: name)
    }

    func updateProfile(name: String, content: String) async {
        await importProfile(name: name, content: content)
    }
}

struct ExportResponse: Codable {
    let name: String
    let content: String
}
