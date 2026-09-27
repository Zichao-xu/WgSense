import SwiftUI
import AppKit

// 菜单栏面板：控制中心 Wi‑Fi 模块的样式。
//
//   顶部   VPN 圆形徽章即开关 + 与主窗口同一口径的状态与原因
//   中部   守护 / 暂停 / 接收 三个等宽模块，开启才上色
//   信息   连接时显示网速，否则显示当前网络
//   底部   系统菜单项样式的“打开 / 退出”
struct MenuBarView: View {
    @EnvironmentObject var client: DaemonClient
    @AppStorage("appLanguage") private var appLanguageRaw = WgAppLanguage.system.rawValue
    @AppStorage("appAppearance") private var appAppearanceRaw = WgAppAppearance.system.rawValue
    @Environment(\.openWindow) var openWindow

    var body: some View {
        let vpn = client.vpnPresentation
        VStack(alignment: .leading, spacing: 0) {
            header(vpn)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)

            HStack(spacing: 8) {
                guardModule
                pauseModule
                receiveModule
            }
            .padding(.horizontal, 12)

            infoLine
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

            Divider().padding(.horizontal, 12)

            VStack(spacing: 0) {
                MenuItemRow(title: "打开 WgSense…", symbol: "macwindow") {
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
                MenuItemRow(title: "退出", symbol: "power", shortcut: "⌘Q") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(6)
        }
        .frame(width: 300)
        .focusEffectDisabled()
        .environment(\.locale, selectedLanguage.locale)
        .preferredColorScheme(selectedAppearance.colorScheme)
        .animation(WgDesign.spring, value: vpn.phase)
        .id("menu-content-\(appLanguageRaw)")
        .task { await refresh() }
    }

    // MARK: - 顶部

    private func header(_ vpn: WgVPNPresentation) -> some View {
        HStack(spacing: 12) {
            Button(action: toggleVPN) {
                WgCircleBadge(symbol: vpn.symbol, tint: vpn.tint, isOn: vpn.isConnected, size: 40, isBusy: vpn.isBusy)
            }
            .buttonStyle(.plain)
            .help(toggleHelp(vpn))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("VPN")
                        .font(.system(size: 13, weight: .semibold))
                    Text(vpn.title)
                        .font(.system(size: 13, weight: vpn.isConnected ? .semibold : .regular))
                        .foregroundStyle(vpn.isConnected ? vpn.tint : Color.secondary)
                }
                Text(vpn.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private func toggleVPN() {
        let vpn = client.vpnPresentation
        Task {
            if vpn.phase == .setupFailed {
                await client.retryServiceInstall()
            } else {
                await client.post(vpn.canDisconnect ? "disconnect" : "connect")
            }
            await client.fetchStatus()
        }
    }

    private func toggleHelp(_ vpn: WgVPNPresentation) -> LocalizedStringKey {
        if vpn.canDisconnect { return "断开 VPN" }
        if vpn.phase == .home { return "在家由守护保持断开；关闭守护后可手动连接" }
        if vpn.phase == .setupFailed { return "重试安装后台服务（会弹一次密码框）" }
        return "连接 VPN"
    }

    // MARK: - 模块

    private var online: Bool { client.status != nil }

    private var guardModule: some View {
        let on = online && client.isGuardOn
        return MenuModule(
            symbol: on ? "shield.fill" : "shield.slash",
            tint: .blue,
            title: "守护",
            status: on ? "运行中" : "已关闭",
            isOn: on,
            isEnabled: online && client.pendingGuardRunning == nil
        ) {
            Task {
                await client.setGuardEnabled(!client.isGuardOn)
                await client.fetchStatus()
            }
        }
    }

    private var pauseModule: some View {
        let on = client.isPauseOn
        return MenuModule(
            symbol: on ? "play.fill" : "pause.fill",
            tint: .orange,
            title: on ? "已暂停" : "暂停",
            status: on ? "点按继续" : "\(client.pauseMinutes) 分钟",
            isOn: on,
            isEnabled: online && client.pendingPaused == nil
        ) {
            Task {
                await client.post(on ? "resume" : "pause")
                await client.fetchStatus()
            }
        }
    }

    private var receiveModule: some View {
        let on = client.transferState?.running ?? false
        return MenuModule(
            symbol: "arrow.down",
            tint: .blue,
            title: "接收",
            status: on ? "已开启" : "已关闭",
            isOn: on,
            isEnabled: client.transferState != nil
        ) {
            Task { _ = await client.setTransferReceiveEnabled(!on) }
        }
    }

    // MARK: - 信息行

    @ViewBuilder
    private var infoLine: some View {
        if client.isTunnelUp {
            HStack(spacing: 14) {
                speed("arrow.down", client.traffic?.rx_speed ?? 0)
                speed("arrow.up", client.traffic?.tx_speed ?? 0)
                Spacer()
                Text(verbatim: client.status?.service ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        } else if let s = client.status {
            HStack(spacing: 6) {
                // 状态已在顶部说明，这里只给网络事实：网卡 + IP。
                let iface = s.network_interfaces?.first
                Image(systemName: iface?.hardware_port?.localizedCaseInsensitiveContains("wi-fi") == true ? "wifi" : "cable.connector")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text(verbatim: iface?.hardware_port ?? iface?.name ?? "—")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let ip = s.primaryIPv4 {
                    Text(verbatim: ip)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        } else {
            Text("后台服务未运行")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func speed(_ symbol: String, _ value: Double) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.tertiary)
            Text(verbatim: WgFormat.speed(value))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
        }
    }

    // MARK: - 其他

    private var selectedLanguage: WgAppLanguage {
        WgAppLanguage(rawValue: appLanguageRaw) ?? .system
    }

    private var selectedAppearance: WgAppAppearance {
        WgAppAppearance(rawValue: appAppearanceRaw) ?? .system
    }

    private func refresh() async {
        await client.fetchStatus()
        await client.fetchTraffic()
        await client.fetchTransferState()
    }
}

/// 控制中心式小模块：圆形徽章 + 标题 + 状态，整块可点。
private struct MenuModule: View {
    var symbol: String
    var tint: Color
    var title: LocalizedStringKey
    var status: LocalizedStringKey
    var isOn: Bool
    var isEnabled: Bool
    var action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WgCircleBadge(symbol: symbol, tint: tint, isOn: isOn, size: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(status)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isEnabled ? 1 : 0.45)
        .wgInteractiveSurface(cornerRadius: 12, isEnabled: isEnabled, action: action)
    }
}

/// 系统菜单项样式：悬停整行高亮为强调色。
private struct MenuItemRow: View {
    var title: LocalizedStringKey
    var symbol: String
    var shortcut: String? = nil
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13))
                Spacer()
                if let shortcut {
                    Text(verbatim: shortcut)
                        .font(.system(size: 12))
                        .foregroundStyle(hovering ? Color.white.opacity(0.8) : Color.secondary)
                }
            }
            .foregroundStyle(hovering ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
