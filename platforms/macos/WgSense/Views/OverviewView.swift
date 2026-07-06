import SwiftUI

// 概览页：总状态卡片 + 各模块摘要
struct OverviewView: View {
    @EnvironmentObject var client: DaemonClient

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("概览").font(.largeTitle).fontWeight(.semibold)

                // 状态卡
                statusCard

                // 模块摘要
                Text("模块").font(.headline)
                VStack(spacing: 8) {
                    moduleRow(icon: "shield.lefthalf.filled", name: "WireGuard", status: wgStatus, color: .blue)
                    moduleRow(icon: "arrow.triangle.2.circlepath", name: "传输", status: "未启用", color: .gray)
                    moduleRow(icon: "globe.asia.australia", name: "代理", status: "未启用", color: .gray)
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
                    Text("Profile: \(s.service) · \(s.at_home ? "在家网段" : "在外") · \(s.paused ? "已暂停" : "自动管理")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func moduleRow(icon: String, name: String, status: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(color).frame(width: 24)
            Text(name)
            Spacer()
            Text(status).font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var wgStatus: String {
        client.status?.state ?? "Unknown"
    }

    private var statusColor: Color {
        switch client.status?.state {
        case "Connected": return .green
        case "Disconnected": return .gray
        default: return .orange
        }
    }
}
