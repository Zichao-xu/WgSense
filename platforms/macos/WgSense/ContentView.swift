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

struct ContentView: View {
    @StateObject private var client = DaemonClient()

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("WgSense")
                .font(.largeTitle)

            if let status = client.status {
                statusRow(label: "隧道状态", value: status.state)
                statusRow(label: "在家网段", value: status.at_home ? "是" : "否")
                statusRow(label: "智能管理", value: status.paused ? "已暂停" : "运行中")
                statusRow(label: "当前 profile", value: status.service)
            } else {
                Text(client.errorMsg ?? "连接中...")
                    .foregroundStyle(.secondary)
            }

            if !client.profiles.isEmpty {
                Text("可用 profile: \(client.profiles.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("连接") { Task { await client.post("connect") } }
                    .buttonStyle(.borderedProminent)
                    .disabled(client.status == nil)

                Button("断开") { Task { await client.post("disconnect") } }
                    .buttonStyle(.bordered)
                    .disabled(client.status == nil)

                Button(client.status?.paused == true ? "恢复" : "暂停") {
                    Task { await client.post(client.status?.paused == true ? "resume" : "pause") }
                }
                .buttonStyle(.bordered)
                .disabled(client.status == nil)
            }
            .padding(.top, 8)

            Spacer()

            Text("阶段 1 · daemon API 已接入")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .task {
            await client.refresh()
        }
    }

    private func statusRow(label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
    }
}

#Preview {
    ContentView()
}
