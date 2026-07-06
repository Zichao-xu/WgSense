import SwiftUI

// WireGuard 模块页：状态 + 控制 + Profile 管理
struct WireGuardView: View {
    @EnvironmentObject var client: DaemonClient

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("WireGuard").font(.largeTitle).fontWeight(.semibold)

                // 状态卡
                statusCard

                // 控制
                Text("控制").font(.headline)
                HStack(spacing: 12) {
                    Button(client.status?.state == "Connected" ? "断开" : "连接") {
                        let ep = client.status?.state == "Connected" ? "disconnect" : "connect"
                        Task { await client.post(ep) }
                    }
                    .buttonStyle(.borderedProminent)

                    Button(client.status?.paused == true ? "恢复自动管理" : "暂停自动管理") {
                        let ep = client.status?.paused == true ? "resume" : "pause"
                        Task { await client.post(ep) }
                    }
                    .buttonStyle(.bordered)
                }

                // 智能管理状态
                Text("智能管理").font(.headline)
                infoCard {
                    infoRow("在家网段", client.status?.at_home == true ? "是" : "否")
                    infoRow("暂停状态", client.status?.paused == true ? "已暂停" : "运行中")
                    infoRow("假连接检测", "每 30s 探测 google.com")
                }

                // Profiles
                Text("Profiles").font(.headline)
                if client.profiles.isEmpty {
                    Text("无可用 profile（放入 ~/.local/share/wgsense/profiles/*.conf）")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(client.profiles, id: \.self) { p in
                            HStack {
                                Image(systemName: client.status?.service == p ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(.tint)
                                Text(p)
                                Spacer()
                                Text(p == client.status?.service ? "当前" : "")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(8)
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private var statusCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(statusColor).frame(width: 12, height: 12)
                    Text(client.status?.state ?? "Unknown")
                        .font(.title2).fontWeight(.medium)
                }
                if let s = client.status {
                    Text("Profile: \(s.service)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func infoCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .padding(12)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
        }
    }

    private var statusColor: Color {
        switch client.status?.state {
        case "Connected": return .green
        case "Disconnected": return .gray
        default: return .orange
        }
    }
}
