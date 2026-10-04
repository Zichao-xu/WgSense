import SwiftUI

// 概览：一眼看清三件事 —— 现在是什么状态、为什么、能做什么。
//
//   主视觉   状态光球 + 标题 + 原因 + 唯一的主操作
//   信息卡   网络 / 守护（可直接开关）/ 流量 / 隧道
//   模块     系统设置式分组列表
struct OverviewView: View {
    @EnvironmentObject var client: DaemonClient

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            WgPageHeader(title: "概览", subtitleText: "WGSENSE · STATUS", word: "OVERVIEW") { EmptyView() }

            hero

            linkStage

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                spacing: 12
            ) {
                networkCard
                guardCard
                trafficCard
                tunnelCard
            }

            modules

            Spacer(minLength: 0)
        }
        .frame(maxWidth: 820, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
        .animation(WgDesign.spring, value: client.vpnPresentation.phase)
        .task {
            async let transfer: Void = client.fetchTransferState()
            async let proxy: Void = client.fetchProxyStatus()
            _ = await (transfer, proxy)
        }

    }

    // MARK: - 主视觉

    private var hero: some View {
        let vpn = client.vpnPresentation
        return HStack(spacing: 20) {
            StatusOrb(symbol: vpn.symbol, tint: vpn.tint, isActive: vpn.phase == .connected || vpn.phase == .home, isBusy: vpn.isBusy)

            VStack(alignment: .leading, spacing: 5) {
                Text(vpn.title)
                    .font(.system(size: 30, weight: .semibold))
                    .contentTransition(.opacity)
                Text(vpn.detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }

            Spacer(minLength: 12)

            primaryAction(vpn)
        }
        .padding(24)
        .wgInteractiveSurface(cornerRadius: WgDesign.heroRadius)
    }

    @ViewBuilder
    private func primaryAction(_ vpn: WgVPNPresentation) -> some View {
        switch vpn.phase {
        case .connected, .connecting, .retrying:
            Button("断开") { Task { await client.post("disconnect") } }
                .buttonStyle(WgCapsuleButtonStyle(tint: .red, prominent: false))
        case .home:
            // 在家保持断开是设计本意，不提供“破例”的主操作；守护开关在下方卡片里。
            EmptyView()
        case .idle, .offline:
            Button("连接") { Task { await client.post("connect") } }
                .buttonStyle(WgCapsuleButtonStyle(tint: .green))
                .disabled(client.isAuthorizingDaemon)
        case .setupFailed:
            Button("重试安装") { Task { await client.retryServiceInstall() } }
                .buttonStyle(WgCapsuleButtonStyle(tint: .orange))
                .disabled(client.isAuthorizingDaemon)
                .help("会再弹一次管理员密码框")
        case .disconnecting:
            ProgressView().controlSize(.small)
        }
    }

    // MARK: - 链路舞台

    /// 事件驱动 HUD：收发构成、握手刻度与最近 30 秒遥测轨迹。
    private var linkStage: some View {
        let phase: WgLinkPhase
        switch client.vpnPresentation.phase {
        case .connected: phase = .linked
        case .home: phase = .home
        case .connecting, .retrying: phase = .connecting
        case .idle, .disconnecting: phase = .idle
        case .offline, .setupFailed: phase = .offline
        }
        return WgLinkStage(phase: phase, monitor: client.linkMonitor)
            .wgInteractiveSurface(cornerRadius: WgDesign.cardRadius)
    }

    // MARK: - 信息卡

    private var networkCard: some View {
        let s = client.status
        let trusted = s?.isTrustedNetwork ?? false
        return InfoCard(
            symbol: trusted ? "house.fill" : "wifi",
            tint: s == nil ? .gray : (trusted ? .teal : .blue),
            title: "网络",
            value: s == nil ? Text("未知") : Text(trusted ? "在家" : "外部网络"),
            detail: networkDetail(s)
        )
    }

    private func networkDetail(_ s: DaemonStatus?) -> Text {
        guard let s else { return Text("等待后台服务") }
        let iface = s.network_interfaces?.first
        let name = iface?.hardware_port ?? iface?.name
        let ip = s.primaryIPv4
        switch (name, ip) {
        case let (n?, i?): return Text(verbatim: "\(n) · \(i)")
        case let (n?, nil): return Text(verbatim: n)
        case let (nil, i?): return Text(verbatim: i)
        default: return Text(s.isTrustedNetwork ? "受信任网络" : "非受信任网络")
        }
    }

    private var guardCard: some View {
        let online = client.status != nil
        let on = online && client.isGuardOn
        return InfoCard(
            symbol: on ? "shield.fill" : "shield.slash.fill",
            tint: on ? .blue : .gray,
            title: "守护",
            value: online ? Text(on ? "运行中" : "已关闭") : Text(verbatim: "—"),
            detail: online ? Text(on ? "在家断开，外出自动连接" : "不会自动连接或断开") : Text("等待后台服务")
        ) {
            Toggle("", isOn: Binding(
                get: { on },
                set: { value in Task { await client.setGuardEnabled(value) } }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .disabled(client.pendingGuardRunning != nil)
        }
    }

    private var trafficCard: some View {
        let up = client.isTunnelUp
        let t = client.traffic
        return InfoCard(
            symbol: "arrow.up.arrow.down",
            tint: up ? .cyan : .gray,
            title: "流量",
            value: up
                ? Text(verbatim: "↓ \(WgFormat.speed(t?.rx_speed ?? 0))   ↑ \(WgFormat.speed(t?.tx_speed ?? 0))")
                : Text(verbatim: "—"),
            detail: up
                ? Text(verbatim: "累计 ↓ \(WgFormat.size(t?.rx_bytes ?? 0)) · ↑ \(WgFormat.size(t?.tx_bytes ?? 0))")
                : Text("隧道未建立")
        )
    }

    private var tunnelCard: some View {
        let s = client.status
        let up = client.isTunnelUp
        let service = (s?.service.isEmpty == false) ? s!.service : "—"
        let detail: Text
        if up, let s {
            let iface = s.tunnel_interface ?? "utun"
            if let age = s.last_handshake_age_seconds {
                detail = Text(verbatim: "\(iface) · ") + Text("握手 \(WgFormat.age(age))")
            } else {
                detail = Text(verbatim: iface)
            }
        } else {
            detail = Text("未建立")
        }
        return InfoCard(
            symbol: "point.3.connected.trianglepath.dotted",
            tint: up ? .green : .gray,
            title: "隧道",
            value: Text(verbatim: service),
            detail: detail
        )
    }

    // MARK: - 模块

    private var modules: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("模块")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            VStack(spacing: 0) {
                ModuleRow(
                    symbol: "lock.shield.fill", tint: .green, name: "WireGuard",
                    status: Text(client.vpnPresentation.title), isOn: client.isTunnelUp
                )
                RowDivider()
                ModuleRow(
                    symbol: "arrow.down", tint: .blue, name: "传输",
                    status: Text(client.transferState?.running == true ? "接收服务运行中" : "未运行"),
                    isOn: client.transferState?.running == true
                )
                RowDivider()
                ModuleRow(
                    symbol: "globe", tint: .purple, name: "代理",
                    status: Text(client.proxyRunning ? "控制器已连接" : (client.proxyServiceRunning ? "等待认证" : "未连接")),
                    isOn: client.proxyRunning
                )
            }
            .wgInteractiveSurface(cornerRadius: WgDesign.cardRadius)
        }
    }
}

// MARK: - 组件

/// 状态块：同心方框收束到一枚实心方块（取自图纸的层层等高线）。
/// 已连接 = 克莱因蓝；在家 = 实墨（安全、无需 VPN）；其余只剩线框。
private struct StatusOrb: View {
    var symbol: String
    var tint: Color
    var isActive: Bool
    var isBusy: Bool

    @State private var spin = false

    var body: some View {
        let normalized = WgInk.normalize(tint)
        let fill: Color = normalized == WgInk.warn || normalized == WgInk.alert ? normalized
            : (tint == .green ? WgInk.signal : WgInk.ink)
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Rectangle()
                    .strokeBorder(Color.primary.opacity(0.28 - Double(i) * 0.08), lineWidth: 1)
                    .frame(width: 60 + CGFloat(i) * 12, height: 60 + CGFloat(i) * 12)
            }
            Rectangle()
                .fill(isActive ? fill : Color.clear)
                .frame(width: 48, height: 48)
            Image(systemName: symbol)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(isActive ? Color(nsColor: .windowBackgroundColor) : Color.primary.opacity(0.6))
                .contentTransition(.symbolEffect(.replace))
            if isBusy {
                Rectangle()
                    .trim(from: 0, to: 0.2)
                    .stroke(fill, style: StrokeStyle(lineWidth: 2))
                    .frame(width: 72, height: 72)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .onAppear {
                        withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { spin = true }
                    }
            }
        }
        .frame(width: 86, height: 86)
        .animation(WgDesign.spring, value: isActive)
    }
}

private struct InfoCard<Accessory: View>: View {
    var symbol: String
    var tint: Color
    var title: LocalizedStringKey
    var value: Text
    var detail: Text
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                WgSquareBadge(symbol: symbol, tint: tint, size: 22)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                accessory()
            }
            .frame(height: 22)
            VStack(alignment: .leading, spacing: 3) {
                value
                    .font(.system(size: 17, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                detail
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .wgInteractiveSurface(cornerRadius: WgDesign.cardRadius)
    }
}

extension InfoCard where Accessory == EmptyView {
    init(symbol: String, tint: Color, title: LocalizedStringKey, value: Text, detail: Text) {
        self.init(symbol: symbol, tint: tint, title: title, value: value, detail: detail) { EmptyView() }
    }
}

private struct ModuleRow: View {
    var symbol: String
    var tint: Color
    var name: LocalizedStringKey
    var status: Text
    var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            WgSquareBadge(symbol: symbol, tint: tint, size: 24, dimmed: !isOn)
            Text(name)
                .font(.system(size: 13, weight: .medium))
            Spacer()
            status
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            WgStatusDot(color: .green, isOn: isOn)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct RowDivider: View {
    var body: some View {
        Divider().opacity(0.5).padding(.leading, 50)
    }
}
