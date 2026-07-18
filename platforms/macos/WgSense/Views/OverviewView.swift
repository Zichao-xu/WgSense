import SwiftUI

// 概览页：Clash Party 风格 — 仪表盘
struct OverviewView: View {
    @EnvironmentObject var client: DaemonClient

    var body: some View {
        VStack(alignment: .leading, spacing: WgTheme.spacing) {
            // 页面标题
            HStack(spacing: 8) {
                Text("概览")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                if let s = client.status {
                    statusPill(s.state)
                }
            }

            // 状态概览卡
            overviewStatusCard

            // 运行信息网格
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: WgTheme.spacing) {
                infoCard(title: "网络", value: networkText, icon: "location.fill", color: networkColor)
                infoCard(title: "守护", value: guardText, icon: "shield.checkered", color: guardColor)
                infoCard(title: "状态", value: stateText, icon: "network", color: statusColor)
            }

            // 模块状态
            moduleSection

            Spacer()
        }
        .task {
            async let transfer: Void = client.fetchTransferState()
            async let proxy: Void = client.fetchProxyStatus()
            _ = await (transfer, proxy)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    // MARK: - 状态 Pill 标签

    private func statusPill(_ state: String) -> some View {
        Text(state)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(statusColorFor(state))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(statusColorFor(state).opacity(0.12))
            .clipShape(Capsule())
    }

    private func statusColorFor(_ state: String) -> Color {
        switch state {
        case "Connected": return .green
        case "Disconnected": return .gray
        default: return .orange
        }
    }

    // MARK: - 主状态卡

    private var overviewStatusCard: some View {
        HStack(spacing: 20) {
            // 左侧：大圆点 + 状态文字
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 14, height: 14)
                        .overlay(
                            Circle()
                                .stroke(statusColor.opacity(0.3), lineWidth: 2)
                        )
                        .shadow(color: statusColor.opacity(0.4), radius: 4)

                    Text(stateText)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                }

                if let s = client.status {
                    VStack(alignment: .leading, spacing: 4) {
                        detailLine("网络", s.isTrustedNetwork ? "受信任" : "非受信任")
                        detailLine("管理", s.paused ? "已暂停" : "自动管理")
                    }
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        detailLine("网络", "等待 daemon")
                        detailLine("管理", "未连接")
                    }
                }
            }

            Spacer()

            // 右侧：大图标装饰
            Image(systemName: isConnected ? "shield.lefthalf.filled" : "shield.slash")
                .font(.system(size: 56))
                .foregroundStyle(statusColor.opacity(isConnected ? 0.5 : 0.15))
        }
        .padding(22)
        .background(WgTheme.cardBg)
        .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius).stroke(WgTheme.cardBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: WgTheme.cardRadius))
    }

    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
    }

    // MARK: - 信息卡片

    private func infoCard(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.headline)
                .fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(WgTheme.cardBg)
        .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius).stroke(WgTheme.cardBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: WgTheme.cardRadius))
    }

    // MARK: - 模块区域

    private var moduleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("模块")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                moduleRow(icon: "shield.lefthalf.filled", name: "WireGuard", desc: wireGuardModuleText, active: client.status != nil, color: .blue)
                Divider().opacity(0.3)
                moduleRow(
                    icon: "arrow.triangle.2.circlepath",
                    name: "传输",
                    desc: client.transferState?.running == true ? "接收服务运行中" : "未运行",
                    active: client.transferState?.running == true,
                    color: .cyan
                )
                Divider().opacity(0.3)
                moduleRow(
                    icon: "globe.asia.australia",
                    name: "代理",
                    desc: client.proxyRunning ? "控制器已连接" : (client.proxyServiceRunning ? "等待认证" : "未连接"),
                    active: client.proxyRunning,
                    color: .purple
                )
            }
            .background(WgTheme.cardBg)
            .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius).stroke(WgTheme.cardBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: WgTheme.cardRadius))
        }
    }

    private func moduleRow(icon: String, name: String, desc: String, active: Bool, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundStyle(active ? color : .secondary.opacity(0.5))
                .frame(width: 22)

            Text(name)
                .fontWeight(.medium)
                .foregroundStyle(active ? .primary : .secondary)

            Spacer()

            Text(desc)
                .font(.caption)
                .foregroundStyle(active ? color : .secondary)

            if active {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(width: 6, height: 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    // MARK: - 辅助属性

    private var isConnected: Bool { client.isVPNOn }

    private var stateText: String {
        client.status?.state ?? "daemon 离线"
    }

    private var networkText: String {
        guard let status = client.status else { return "未知" }
        return status.isTrustedNetwork ? "受信任" : "非受信任"
    }

    private var networkColor: Color {
        guard let status = client.status else { return .secondary }
        return status.isTrustedNetwork ? .green : .blue
    }

    private var guardText: String {
        guard let status = client.status else { return "未连接" }
        return status.paused ? "已暂停" : "运行中"
    }

    private var guardColor: Color {
        guard let status = client.status else { return .secondary }
        return status.paused ? .gray : .green
    }

    private var wireGuardModuleText: String {
        guard let status = client.status else { return "daemon 未连接" }
        return status.state
    }

    private var statusColor: Color {
        switch client.status?.state {
        case "Connected": return .green
        case "Disconnected": return .gray
        case nil: return .secondary
        default: return .orange
        }
    }
}
