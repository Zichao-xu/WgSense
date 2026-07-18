import SwiftUI
import AppKit

// 菜单栏下拉：状态 + 快速开关
struct MenuBarView: View {
    @EnvironmentObject var client: DaemonClient
    @Environment(\.openWindow) var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: client.isVPNOn ? "shield.fill" : "shield.slash")
                    .font(.title2)
                    .foregroundStyle(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("WgSense").font(.headline)
                    Text(localizedState)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help("刷新状态")
            }
            if let s = client.status {
                HStack(spacing: 4) {
                    Text(s.service)
                    Text("·")
                    Text(networkTitle(isTrusted: s.isTrustedNetwork))
                }
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("daemon 未连接")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                menuMetric("arrow.up", value: formatSpeed(client.traffic?.tx_speed ?? 0))
                menuMetric("arrow.down", value: formatSpeed(client.traffic?.rx_speed ?? 0))
                Spacer()
                Label(receiveStateTitle, systemImage: "tray.and.arrow.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider()

            menuToggle(
                title: "VPN",
                symbol: "network",
                isOn: client.isVPNOn,
                disabled: client.pendingConnected != nil
            ) { enabled in
                Task {
                    await client.post(enabled ? "connect" : "disconnect")
                    await client.fetchStatus()
                }
            }
            menuToggle(
                title: "守护",
                symbol: "shield.checkered",
                isOn: client.isGuardOn,
                disabled: client.pendingGuardRunning != nil
            ) { enabled in
                Task {
                    await client.setGuardEnabled(enabled)
                    await client.fetchStatus()
                }
            }
            menuToggle(title: "暂停", symbol: "pause.circle", isOn: client.isPauseOn, disabled: client.pendingPaused != nil) { enabled in
                Task {
                    await client.post(enabled ? "pause" : "resume")
                    await client.fetchStatus()
                }
            }
            menuToggle(title: "LocalSend 接收", symbol: "tray.and.arrow.down.fill", isOn: client.transferState?.running ?? false) { enabled in
                Task { _ = await client.setTransferReceiveEnabled(enabled) }
            }

            Divider()

            Button {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            } label: {
                Label("打开主窗口", systemImage: "macwindow")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("退出 WgSense", systemImage: "power")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 286)
        .task { await refresh() }
    }

    private var localizedState: LocalizedStringKey {
        switch client.status?.state {
        case "Connected": return "已连接"
        case "Disconnected": return "未连接"
        default: return "状态未知"
        }
    }

    private func refresh() async {
        await client.fetchStatus()
        await client.fetchTraffic()
        await client.fetchTransferState()
    }

    private func menuToggle(
        title: LocalizedStringKey,
        symbol: String,
        isOn: Bool,
        disabled: Bool = false,
        action: @escaping (Bool) -> Void
    ) -> some View {
        HStack {
            Label(title, systemImage: symbol)
            Spacer()
            Toggle("", isOn: Binding(get: { isOn }, set: action))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(disabled)
        }
    }

    private func menuMetric(_ symbol: String, value: String) -> some View {
        Label(value, systemImage: symbol)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    private func formatSpeed(_ value: Double) -> String {
        if value < 1024 { return String(format: "%.0f B/s", value) }
        if value < 1024 * 1024 { return String(format: "%.1f KB/s", value / 1024) }
        return String(format: "%.1f MB/s", value / 1024 / 1024)
    }

    private func networkTitle(isTrusted: Bool) -> LocalizedStringKey {
        isTrusted ? "受信任网络" : "非受信任网络"
    }

    private var receiveStateTitle: LocalizedStringKey {
        client.transferState?.running == true ? "接收已开启" : "接收已关闭"
    }

    private var statusColor: Color {
        switch client.status?.state {
        case "Connected": return .green
        case "Disconnected": return .gray
        default: return .orange
        }
    }
}
