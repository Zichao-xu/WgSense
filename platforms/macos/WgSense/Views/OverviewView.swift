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

                // 说明“为什么是现在这个状态”，网络/守护细节见下方卡片。
                Text(reasonText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // 右侧：大图标装饰
            Image(systemName: isConnected ? "shield.lefthalf.filled" : "shield.slash")
                .font(.system(size: 56))
                .foregroundStyle(statusColor.opacity(isConnected ? 0.5 : 0.15))
        }
        .padding(22)
        .wgGlassSurface(cornerRadius: WgTheme.controlRadius, tint: statusColor, interactive: true)
    }

    // MARK: - 信息卡片

    private func infoCard(title: LocalizedStringKey, value: LocalizedStringKey, icon: String, color: Color) -> some View {
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
        .wgGlassSurface(tint: color)
    }

    // MARK: - 模块区域

    private var moduleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("模块")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                moduleRow(icon: "shield.lefthalf.filled", name: "WireGuard", desc: wireGuardModuleText, active: client.isTunnelUp, color: .green)
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
            .wgGlassSurface()
        }
    }

    private func moduleRow(icon: String, name: LocalizedStringKey, desc: LocalizedStringKey, active: Bool, color: Color) -> some View {
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

    private var isConnected: Bool { client.isTunnelUp }

    private var reasonText: LocalizedStringKey {
        guard let s = client.status else { return "后台服务未运行" }
        let guardOn = s.desired_guard_enabled ?? !s.paused
        let wantVPN = s.desired_vpn_enabled ?? false
        switch s.state {
        case "Connected":
            if s.isTrustedNetwork && guardOn { return "受信任网络，手动连接优先；换网络或手动断开后交还守护" }
            return "隧道已建立"
        case "Connecting":
            return "正在连接…"
        case "Disconnecting":
            return "正在断开…"
        default:
            if wantVPN {
                if let failures = s.auto_failures, failures > 0 { return "连接失败，正在自动重试（第 \(failures) 次）" }
                return "正在尝试连接…"
            }
            if s.isTrustedNetwork && guardOn { return "受信任网络，守护保持断开" }
            if !guardOn { return "守护已关闭，需要时手动连接" }
            return "未连接"
        }
    }

    private var stateText: LocalizedStringKey {
        guard let state = client.status?.state else { return "daemon 离线" }
        return localizedStatus(state)
    }

    private var networkText: LocalizedStringKey {
        guard let status = client.status else { return "未知" }
        return status.isTrustedNetwork ? "受信任" : "非受信任"
    }

    private var networkColor: Color {
        guard let status = client.status else { return .secondary }
        return status.isTrustedNetwork ? .green : .blue
    }

    private var guardText: LocalizedStringKey {
        guard let status = client.status else { return "未连接" }
        return status.paused ? "已暂停" : "运行中"
    }

    private var guardColor: Color {
        guard let status = client.status else { return .secondary }
        return status.paused ? .gray : .green
    }

    private var wireGuardModuleText: LocalizedStringKey {
        guard let status = client.status else { return "daemon 未连接" }
        return localizedStatus(status.state)
    }

    private func localizedStatus(_ state: String) -> LocalizedStringKey {
        switch state {
        case "Connected": return "已连接"
        case "Disconnected": return "未连接"
        case "Connecting": return "连接中"
        case "Disconnecting": return "断开中"
        default: return "状态未知"
        }
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
