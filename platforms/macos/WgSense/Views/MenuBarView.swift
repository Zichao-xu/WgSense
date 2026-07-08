import SwiftUI
import AppKit

// 菜单栏下拉：状态 + 快速开关
struct MenuBarView: View {
    @EnvironmentObject var client: DaemonClient
    @Environment(\.openWindow) var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 状态行
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(client.status?.state ?? "Unknown")
                    .font(.headline)
            }
            if let s = client.status {
                Text("\(s.service) · \(s.at_home ? "在家" : "在外")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("daemon 未连接")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // 快速开关
            HStack(spacing: 8) {
                Button(client.status?.state == "Connected" ? "断开" : "连接") {
                    let ep = client.status?.state == "Connected" ? "disconnect" : "connect"
                    Task { await client.post(ep) }
                }
                Button(client.status?.paused == true ? "恢复" : "暂停") {
                    let ep = client.status?.paused == true ? "resume" : "pause"
                    Task { await client.post(ep) }
                }
            }
            .buttonStyle(.bordered)

            Divider()

            Button("打开主窗口") {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(10)
        .frame(width: 220)
        .task { await client.fetchStatus() }
    }

    private var statusColor: Color {
        switch client.status?.state {
        case "Connected": return .green
        case "Disconnected": return .gray
        default: return .orange
        }
    }
}
