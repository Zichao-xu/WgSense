import SwiftUI

struct DaemonStatus: Codable {
    let at_home: Bool
    let state: String
    let paused: Bool
    let service: String
}

@MainActor
class DaemonClient: ObservableObject {
    @Published var status: DaemonStatus?
    @Published var profiles: [String] = []
    @Published var errorMsg: String?

    private let baseURL = URL(string: "http://127.0.0.1:8765")!
    private var pollTimer: Timer?

    init() {
        startPolling()
    }

    deinit {
        pollTimer?.invalidate()
    }

    /// 启动定时轮询，确保菜单栏图标状态始终最新
    func startPolling(interval: TimeInterval = 5.0) {
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
        var req = URLRequest(url: baseURL.appendingPathComponent("api/\(endpoint)"))
        req.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: req)
        await fetchStatus()
    }
}
