import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

// MARK: - 主题色（Clash Party 风格）

enum WgTheme {
    static let bg = Color(red: 0.08, green: 0.08, blue: 0.09)
    static let sidebarBg = Color(red: 0.06, green: 0.06, blue: 0.07)
    static let cardBg = Color.white.opacity(0.05)
    static let cardBorder = Color.white.opacity(0.06)
    static let accent = Color(red: 0.2, green: 0.5, blue: 0.95)
    static let cardRadius: CGFloat = 10
    static let spacing: CGFloat = 12
    static let pagePadding: CGFloat = 28
    /// 磁贴尺寸基准：小磁贴高=y, 宽=x; 中=高y宽2x; 大=2y×2x; 间距=y/10
    /// 设 y=80 → small: 80×(80/0.618)≈80×129, medium: 80×259, large: 160×259
    static let tileY: CGFloat = 80
    static let tileX: CGFloat = tileY / 0.618
    static let tileGap: CGFloat = tileY / 10
}

extension View {
    func wgGlassSurface(
        cornerRadius: CGFloat = 12,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background(shape.fill(WgTheme.cardBg))
            .overlay {
                shape.fill(tint?.opacity(interactive ? 0.18 : 0.12) ?? Color.clear)
            }
            .overlay(shape.stroke(WgTheme.cardBorder, lineWidth: 0.75))
    }

    func wgTimelineScroller() -> some View {
        self
    }
}

// MARK: - 主窗口

struct MainView: View {
    @EnvironmentObject var client: DaemonClient
    @State private var selection: SidebarTab = .dashboard

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(selection: $selection)
                .frame(width: 260)
                .background(WgTheme.sidebarBg)

            Rectangle()
                .fill(WgTheme.cardBorder)
                .frame(width: 1)

            ScrollView {
                Group {
                    switch selection {
                    case .dashboard, .wireguard: OverviewView()
                    case .proxy: ProxyView()
                    case .profile: ProfileManagerView()
                    case .transferReceive: TransferReceiveView()
                    case .transferSend: TransferSendView()
                    case .settings: SettingsView()
                    case .logs: LogsView()
                    case .about: AboutView()
                    }
                }
                .padding(28)
            }
            .background(WgTheme.bg)
        }
        .frame(minWidth: 780, minHeight: 500)
        .task { await client.refresh() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            Task { await client.fetchStatus() }
        }
    }
}

// MARK: - Tab 枚举

enum SidebarTab: String, CaseIterable, Identifiable {
    case dashboard, wireguard, proxy, profile, transferReceive, transferSend, settings, logs, about
    var id: String { rawValue }

    var label: String {
        switch self {
        case .dashboard: return "概览"
        case .wireguard: return "WireGuard"
        case .proxy: return "代理"
        case .profile: return "配置"
        case .transferReceive: return "接收"
        case .transferSend: return "发送"
        case .settings: return "设置"
        case .logs: return "日志"
        case .about: return "关于"
        }
    }
}

// MARK: - 磁贴数据模型

enum TileKind: String, CaseIterable, Identifiable, Codable {
    case vpn, guardMode, pause, stop, transferReceive, transferSend, proxy, profile, logs, about, connection
    var id: String { rawValue }

    var title: String {
        switch self {
        case .vpn: return "VPN"
        case .guardMode: return "守护"
        case .pause: return "暂停"
        case .stop: return "停止"
        case .transferReceive: return "接收"
        case .transferSend: return "发送"
        case .proxy: return "代理"
        case .profile: return "配置"
        case .logs: return "日志"
        case .about: return "关于"
        case .connection: return "连接"
        }
    }

    var icon: String {
        switch self {
        case .vpn: return "network"
        case .guardMode: return "shield.checkered"
        case .pause: return "pause.circle.fill"
        case .stop: return "stop.circle.fill"
        case .transferReceive: return "arrow.down.circle.fill"
        case .transferSend: return "arrow.up.circle.fill"
        case .proxy: return "globe.asia.australia"
        case .profile: return "doc.text.fill"
        case .logs: return "scroll"
        case .about: return "info.circle"
        case .connection: return "arrow.up.arrow.down.circle"
        }
    }

    var activeColor: Color {
        switch self {
        case .vpn: return .green
        case .guardMode: return .blue
        case .pause: return .orange
        case .stop: return .red
        case .transferReceive: return .blue
        case .transferSend: return .orange
        case .proxy: return .purple
        case .profile: return .orange
        case .logs: return .secondary
        case .about: return .secondary
        case .connection: return .cyan
        }
    }

    /// 默认尺寸（首次添加时使用，之后可切换）
    var defaultSize: TileSize {
        switch self {
        case .connection: return .medium
        default: return .small
        }
    }
}

enum TileSize: String, Codable, CaseIterable {
    case small   // 1 格子（半行）— 正方形
    case medium  // 2 格子（全宽一行）
    case large   // 4 格子（全宽两行）

    /// 固定高度倍数（以 small 高度为 1 单位）
    var heightUnits: Int {
        switch self {
        case .small: return 1
        case .medium: return 1   // 一行高
        case .large: return 2    // 两行高
        }
    }
}

struct TileData: Identifiable, Codable {
    let id: UUID
    var kind: TileKind
    var size: TileSize

    init(id: UUID = UUID(), kind: TileKind, size: TileSize? = nil) {
        self.id = id
        self.kind = kind
        self.size = size ?? kind.defaultSize
    }
}

// MARK: - 侧边栏（iOS 桌面风格磁贴系统）

struct SidebarView: View {
    @Binding var selection: SidebarTab
    @EnvironmentObject var client: DaemonClient
    @State private var tiles: [TileData] = []
    @State private var isEditMode = false
    @State private var draggedItem: TileData?
    @State private var showDeleteConfirm = false
    @State private var showAddSheet = false
    @State private var showProfileDeleteConfirm = false
    @State private var contextMenuTile: TileData? = nil  // 长按/右键磁贴时弹菜单
    @State private var contextMenuAnchor: CGPoint = .zero

    // VPN 状态快捷访问
    private var isConnected: Bool { client.isVPNOn }
    private var guardRunning: Bool { client.isGuardOn }

    init(selection: Binding<SidebarTab>) {
        self._selection = selection
        _tiles = State(initialValue: Self.defaultTiles())
    }

    static func defaultTiles() -> [TileData] {
        [
            TileData(kind: .vpn),
            TileData(kind: .guardMode),
            TileData(kind: .pause),
            TileData(kind: .stop),
            TileData(kind: .transferReceive),
            TileData(kind: .transferSend),
            TileData(kind: .proxy),
            TileData(kind: .profile),
            TileData(kind: .logs),
            TileData(kind: .about),
            TileData(kind: .connection),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().opacity(0.15).padding(.horizontal, 12)

            // 磁贴网格区域
            ScrollView {
                tileGridContent
            }

            Spacer(minLength: 0)
        }
        .sheet(isPresented: $showAddSheet) { AddTileSheet(existingKinds: tiles.map(\.kind)) { kind in
            tiles.append(TileData(kind: kind))
            showAddSheet = false
        }}
        .confirmationDialog("确认删除配置？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let name = client.status?.service {
                    Task {
                        await client.postAndWait("pause")
                        await client.postAndWait("disconnect")
                        await client.deleteProfile(name: name)
                        await client.fetchProfiles()
                        await client.fetchStatus()
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将断开 WG 并删除当前 profile「\(client.status?.service ?? "")」，此操作不可撤销。")
        }
    }

    // MARK: - 头部

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.green)
            Text("WgSense").font(.headline).fontWeight(.bold)
            Spacer()

            // 添加磁贴按钮（编辑模式下高亮）
            Button { showAddSheet = true } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(isEditMode ? WgTheme.accent : .secondary)
            }.buttonStyle(.plain)

            // 编辑模式切换按钮
            Button { withAnimation(.spring(response: 0.35)) { isEditMode.toggle() } } label: {
                Image(systemName: isEditMode ? "checkmark.circle.fill" : "pencil.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isEditMode ? .green : .secondary)
            }.buttonStyle(.plain)

            // 设置图标按钮
            Button { withAnimation(.easeInOut(duration: 0.15)) { selection = .settings } } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16))
                    .foregroundStyle(selection == .settings ? WgTheme.accent : .secondary)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Tab 行

    private var tabRow: some View {
        let topTabs: [SidebarTab] = [.dashboard, .profile, .settings]  // 概览 + 配置 + 设置
        return HStack(spacing: 6) {
            ForEach(topTabs) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selection = tab }
                } label: {
                    Text(tab.label)
                        .font(.subheadline)
                        .fontWeight(selection == tab ? .semibold : .regular)
                        .foregroundStyle(selection == tab ? .primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8)
                            .fill(selection == tab ? WgTheme.accent : Color.clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    // MARK: - 磁贴内容视图

    @ViewBuilder
    private func tileContent(_ tile: TileData) -> some View {
        // 小磁贴：统一风格（右侧半透明大图标 + 左侧大字）
        if tile.size == .small {
            return AnyView(smallTileBody(tile))
        }

        let content = Group {
            switch tile.kind {
            case .vpn: vpnTile(tile)
            case .guardMode: guardTile(tile)
            case .pause: pauseTile(tile)
            case .stop: stopTile(tile)
            case .transferReceive: receiveTile(tile)
            case .transferSend: sendTile(tile)
            case .proxy: proxyTile(tile)
            case .profile: profileTile(tile)
            case .logs:
                if tile.size == .small {
                    navTile(tile, isSelected: selection == .logs)
                } else {
                    logContentTile(tile)  // 中/大尺寸显示滚动日志
                }
            case .about: navTile(tile, isSelected: selection == .about)
            case .connection: connectionTile(tile)
            }
        }
        .modifier(EditShakeModifier(isShaking: isEditMode && draggedItem?.id != tile.id))
        .overlay(alignment: .topTrailing) {
            if isEditMode { editOverlay(tile) }
        }

        return AnyView(content)
    }

    /// 小磁贴统一样式：右侧半透明大图标背景 + 左侧标题
    @ViewBuilder
    private func smallTileBody(_ tile: TileData) -> some View {
        let iconColor = tile.kind.activeColor

        // 控制类磁贴：显示操作按钮
        if tile.kind == .vpn || tile.kind == .guardMode || tile.kind == .pause {
            return AnyView(smallControlTile(tile, iconColor: iconColor))
        }

        return AnyView(
            Button {
                handleSmallTileTap(tile)
            } label: {
                ZStack(alignment: .topLeading) {
                    Image(systemName: tile.kind.icon)
                        .font(.system(size: 48, weight: .ultraLight))
                        .foregroundStyle(iconColor.opacity(0.12))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .offset(x: 4, y: 4)

                    // 小磁贴统一：标题左上角 + 图标背景右下角
                    Text(tile.kind.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.leading, 10)
                        .padding(.top, 10)
                }
            }
            .buttonStyle(.plain)
            .background(WgTheme.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: WgTheme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius).stroke(WgTheme.cardBorder, lineWidth: 1))
            .modifier(EditShakeModifier(isShaking: isEditMode && draggedItem?.id != tile.id))
            .overlay(alignment: .topTrailing) {
                if isEditMode { editOverlay(tile) }
            }
            // 日志数据后台持续拉取（切换到中/大尺寸时立即可用）
            .task {
                if tile.kind == .logs {
                    await client.fetchLogs(n: 15)
                    while !Task.isCancelled && tile.kind == .logs {
                        try? await Task.sleep(for: .seconds(3))
                        await client.fetchLogs(n: 15)
                    }
                }
            }
        )
    }

    /// 小尺寸控制磁贴（VPN/守护/暂停）— 原生 Toggle 开关
    private func smallControlTile(_ tile: TileData, iconColor: Color) -> some View {
        let isOn: Bool
        let tintColor: Color

        switch tile.kind {
        case .vpn:
            isOn = isConnected; tintColor = .green
        case .guardMode:
            isOn = guardRunning; tintColor = .blue
        case .pause:
            isOn = client.isPauseOn; tintColor = .orange
        default:
            isOn = false; tintColor = .gray
        }

        return Button {
            switch tile.kind {
            case .vpn:
                Task { await client.post(isConnected ? "disconnect" : "connect") }
            case .guardMode:
                Task { await client.setGuardEnabled(!guardRunning) }
            case .pause:
                Task { await client.post(client.isPauseOn ? "resume" : "pause") }
            default: break
            }
        } label: {
            ZStack {
                // 背景层：右下角半透明大图标
                Image(systemName: tile.kind.icon)
                    .font(.system(size: 48, weight: .ultraLight))
                    .foregroundStyle(iconColor.opacity(0.10))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .offset(x: 4, y: 4)

                // 左上角：标题文字（横向）
                Text(tile.kind.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, 10)
                    .padding(.top, 10)

                // 右上角：Toggle 开关
                ToggleSwitch(isOn: isOn, tintColor: tintColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(10)

                // 左下角：状态圆点
                Circle()
                    .fill(isOn ? tintColor : Color.gray.opacity(0.35))
                    .frame(width: 7, height: 7)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(10)
            }
        }
        .buttonStyle(.plain)
        .background(WgTheme.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: WgTheme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius).stroke(WgTheme.cardBorder, lineWidth: 1))
        .modifier(EditShakeModifier(isShaking: isEditMode && draggedItem?.id != tile.id))
        .overlay(alignment: .topTrailing) {
            if isEditMode { editOverlay(tile) }
        }
    }

    /// 小磁贴点击处理
    private func handleSmallTileTap(_ tile: TileData) {
        withAnimation(.easeInOut(duration: 0.15)) {
            switch tile.kind {
            case .vpn, .connection: selection = .dashboard
            case .proxy: selection = .proxy
            case .profile: selection = .profile
            case .transferReceive: selection = .transferReceive
            case .transferSend: selection = .transferSend
            case .logs: selection = .logs
            case .about: selection = .about
            case .guardMode: selection = .settings
            case .pause, .stop: break
            }
        }
    }

    // MARK: 各类型磁贴

    // --- VPN 磁贴 ---
    private func vpnTile(_ tile: TileData) -> some View {
        controlTile(
            tile: tile,
            icon: tile.kind.icon,
            color: tile.kind.activeColor,
            subtitle: isConnected ? "已连" : "断开",
            isOn: isConnected
        ) {
            Task { await client.post(isConnected ? "disconnect" : "connect") }
        } onTap: {
            withAnimation(.easeInOut(duration: 0.15)) { selection = .dashboard }
        }
    }

    // --- 守护磁贴 ---
    private func guardTile(_ tile: TileData) -> some View {
        controlTile(
            tile: tile,
            icon: tile.kind.icon,
            color: tile.kind.activeColor,
            subtitle: guardRunning ? "运行中" : "暂停",
            isOn: guardRunning
        ) {
            Task { await client.setGuardEnabled(!guardRunning) }
        } onTap: {
            withAnimation(.easeInOut(duration: 0.15)) { selection = .settings }
        }
    }

    // --- 暂停磁贴 ---
    private func pauseTile(_ tile: TileData) -> some View {
        actionTile(
            tile: tile,
            icon: tile.kind.icon,
            color: tile.kind.activeColor,
            subtitle: "\(client.pauseMinutes)分钟",
            actionLabel: "执行"
        ) {
            Task {
                await client.post("pause")
                await client.post("disconnect")
                let m = client.pauseMinutes
                try? await Task.sleep(nanoseconds: UInt64(m) * 60_000_000_000)
                await client.post("resume")
                await client.post("connect")
            }
        }
    }

    // --- 停止磁贴（紧急停止：关闭守护 + 断开 WG）---
    private func stopTile(_ tile: TileData) -> some View {
        controlTile(
            tile: tile,
            icon: "stop.circle.fill",
            color: .red,
            subtitle: "全部关闭",
            isOn: false,
            toggleAction: {
                Task {
                    await client.post("disconnect")  // 先断 WG
                    try? await Task.sleep(for: .milliseconds(300))
                    await client.post("pause")      // 再停守护
                }
            },
            onTap: { /* 点击非控制区域不做导航 */ }
        )
    }

    // --- 接收磁贴（LocalSend 兼容）---
    @ViewBuilder
    private func receiveTile(_ tile: TileData) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { selection = .transferReceive }
        } label: {
            VStack(alignment: .leading, spacing: tile.size == .small ? 4 : 8) {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: tile.size == .small ? 14 : 20))
                        .foregroundStyle(.blue)
                    Text("接收")
                        .font(.system(size: tile.size == .small ? 11 : 14, weight: .bold))
                        .foregroundStyle(.primary)
                    Spacer()
                    receiveStatusBadge
                }
                if tile.size != .small {
                    receiveTileDetail(size: tile.size)
                }
            }
            .padding(tile.size == .small ? 10 : 16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: WgTheme.cardRadius)
                    .fill(Color.blue.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius)
                        .stroke(selection == .transferReceive ? Color.blue : Color.clear,
                                lineWidth: selection == .transferReceive ? 1.5 : 0))
            )
        }
        .buttonStyle(.plain)
    }

    private var receiveStatusBadge: some View {
        Group {
            if let state = client.transferState {
                HStack(spacing: 4) {
                    if state.pending.isEmpty {
                        Circle().fill(state.running ? Color.green : Color.red).frame(width: 7, height: 7)
                        Text(state.running ? "运行中" : "已停止")
                            .font(.caption2).foregroundStyle(state.running ? .green : .red)
                    } else {
                        Image(systemName: "tray.and.arrow.down.fill")
                        Text("\(state.pending.count) 待确认")
                    }
                }
                .font(.caption2)
                .foregroundStyle(state.pending.isEmpty ? (state.running ? Color.green : Color.red) : Color.orange)
            } else {
                Text("--").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func receiveTileDetail(size: TileSize) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if size == .large, let state = client.transferState {
                // 大尺寸：显示别名 + 端口 + 自动保存状态
                Text(state.alias)
                    .font(.caption).foregroundStyle(.secondary)
                Divider().opacity(0.1)
                HStack(spacing: 12) {
                    Label(":\(state.port)", systemImage: "network")
                    Label("自动保存: 关", systemImage: "tray.full")
                }
                .font(.caption2).foregroundStyle(.tertiary)
            } else if let state = client.transferState {
                // 中尺寸：简洁信息
                Text("\(state.alias) · :\\(state.port)")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("LocalSend 接收服务")
                    .font(.caption).foregroundStyle(.secondary)
                Divider().opacity(0.1)
                Text("点击进入").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    // --- 发送磁贴（LocalSend 兼容）---
    @ViewBuilder
    private func sendTile(_ tile: TileData) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { selection = .transferSend }
        } label: {
            VStack(alignment: .leading, spacing: tile.size == .small ? 4 : 8) {
                HStack {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: tile.size == .small ? 14 : 20))
                        .foregroundStyle(.orange)
                    Text("发送")
                        .font(.system(size: tile.size == .small ? 11 : 14, weight: .bold))
                        .foregroundStyle(.primary)
                    Spacer()
                    sendStatusBadge
                }
                if tile.size != .small {
                    sendTileDetail(size: tile.size)
                }
            }
            .padding(tile.size == .small ? 10 : 16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: WgTheme.cardRadius)
                    .fill(Color.orange.opacity(0.08))
                    .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius)
                        .stroke(selection == .transferSend ? Color.orange : Color.clear,
                                lineWidth: selection == .transferSend ? 1.5 : 0))
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var sendStatusBadge: some View {
        let count = client.transferDevices.count
        if count > 0 {
            Text("\(count) 设备")
                .font(.caption2)
                .foregroundStyle(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.12))
                .cornerRadius(4)
        } else {
            Text("--").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func sendTileDetail(size: TileSize) -> some View {
        let count = client.transferDevices.count
        VStack(alignment: .leading, spacing: 6) {
            if count > 0 && size == .large {
                // 大尺寸：设备列表预览
                ForEach(client.transferDevices.prefix(3)) { device in
                    HStack(spacing: 6) {
                        Circle().fill(colorForDeviceSource(device.source ?? "multicast")).frame(width: 6, height: 6)
                        Text(device.alias).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(device.ip ?? "").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if count > 3 { Text("... 还有 \(count - 3) 个").font(.caption2).foregroundStyle(.tertiary) }
            } else if count > 0 {
                // 中尺寸：设备数量
                Text("发现 \(count) 台设备")
                    .font(.caption).foregroundStyle(.secondary)
                Divider().opacity(0.1)
                Text("点击进入发送").font(.caption2).foregroundStyle(.tertiary)
            } else {
                Text("扫描或手动添加设备")
                    .font(.caption).foregroundStyle(.secondary)
                Divider().opacity(0.1)
                Text("隧道内传输").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// 设备来源对应的颜色
    private func colorForDeviceSource(_ source: String) -> Color {
        switch source {
        case "manual": return .orange
        case "scan": return .blue
        default: return .green
        }
    }

    // --- 代理磁贴 ---
    private func proxyTile(_ tile: TileData) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { selection = .proxy }
        } label: {
            VStack(alignment: .leading, spacing: tile.size == .small ? 4 : 8) {
                HStack(spacing: 8) {
                    Image(systemName: "globe.asia.australia")
                        .font(.system(size: tileSizeIcon(tile.size) - 4))
                        .foregroundStyle(client.proxyRunning ? .purple : .secondary.opacity(0.5))
                    Text(client.proxyRunning ? (client.mihomoVersion?.version ?? "Mihomo") : "未连接")
                        .font(tile.size == .small ? .subheadline : (tile.size == .medium ? .body : .title3))
                        .fontWeight(.semibold).lineLimit(1)
                    Spacer()
                }

                HStack(spacing: 6) {
                    Circle()
                        .fill(client.proxyRunning ? Color.purple : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                    Text(client.proxyRunning ? "运行中" : "离线")
                        .font(.caption2).fontWeight(.medium)
                        .foregroundStyle(client.proxyRunning ? .purple : .secondary)
                    if !client.proxyAddress.isEmpty {
                        Text(client.proxyAddress)
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer()
                }

                if tile.size == .large {
                    if let conns = client.connections {
                        HStack(spacing: 12) {
                            statItem("↑", formatSpeed(client.traffic?.tx_speed ?? 0), .blue)
                            statItem("↓", formatSpeed(client.traffic?.rx_speed ?? 0), .green)
                            statItem("链接", "\(conns.connections.count)", .orange)
                        }
                        .padding(.top, 4)
                    }
                }
            }
            .padding(tile.size == .small ? 12 : 16)
        }
        .buttonStyle(.plain)
        .background(WgTheme.cardBg)
        .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius).stroke(WgTheme.cardBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: WgTheme.cardRadius))
        .task(id: UUID()) {
            await client.fetchProxyStatus()
            if client.proxyRunning {
                await client.fetchProxyVersion()
                await client.fetchConnections()
            }
        }
    }

    private func statItem(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(color)
            Text(value).font(.caption).fontWeight(.medium).monospacedDigit()
        }
    }

    private func formatSpeed(_ bytesPerSec: Int64?) -> String {
        guard let bps = bytesPerSec, bps > 0 else { return "0 B/s" }
        if bps < 1024 { return "\(bps) B/s" }
        if bps < 1024 * 1024 { return "\(bps / 1024) KB/s" }
        return String(format: "%.1f MB/s", Double(bps) / 1024.0 / 1024.0)
    }

    // --- Profile 磁贴（内容随尺寸自适应）---
    private func profileTile(_ tile: TileData) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { selection = .profile }
        } label: {
            VStack(alignment: .leading, spacing: tile.size == .small ? 4 : 8) {
                // 第一行：图标 + 名称
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: tileSizeIcon(tile.size) - 4))
                        .foregroundStyle(.orange)
                    Text(client.profiles.isEmpty ? "无配置" : client.profiles.joined(separator: ", "))
                        .font(tile.size == .small ? .subheadline : (tile.size == .medium ? .body : .title3))
                        .fontWeight(.semibold).lineLimit(1)
                    Spacer()
                    if !isEditMode {
                        Button { /* TODO: edit */ } label: {
                            Image(systemName: "pencil").font(.system(size: 11)).foregroundStyle(.secondary.opacity(0.6))
                        }.buttonStyle(.plain)
                    }
                }

                // 第二行：标签 + 状态
                HStack(spacing: 6) {
                    Text("本地")
                        .font(.caption2).fontWeight(.medium).foregroundStyle(Color.cyan)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Color.cyan.opacity(0.12)).clipShape(Capsule())
                    if let s = client.status {
                        Text(s.at_home ? "在家网段" : "在外")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !isEditMode && tile.size != .small {
                        Button { showDeleteConfirm = true } label: {
                            Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(.red.opacity(0.45))
                        }.buttonStyle(.plain)
                    }
                }

                // 中尺寸：状态摘要
                if tile.size == .medium {
                    HStack(spacing: 6) {
                        Circle().fill(isConnected ? Color.green : Color.gray.opacity(0.3))
                            .frame(width: 6, height: 6)
                        Text(isConnected ? "已连接" : "未连接")
                            .font(.system(size: 10)).foregroundStyle(isConnected ? .green : .secondary)
                        Spacer()
                    }
                }

                // 大尺寸时展示额外信息（连接状态、操作按钮等）
                if tile.size == .large {
                    Divider().opacity(0.2)
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(isConnected ? "已连接" : "未连接", systemImage: isConnected ? "checkmark.circle.fill" : "circle")
                                .font(.caption2)
                                .foregroundStyle(isConnected ? .green : .secondary)
                            Label(client.status?.state ?? "未知", systemImage: "network")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        VStack(spacing: 8) {
                            Button { Task { await client.post("disconnect") } } label: {
                                Text("断开")
                                    .font(.caption2).fontWeight(.medium)
                                    .padding(.horizontal, 12).padding(.vertical, 4)
                                    .background(Color.red.opacity(0.15))
                                    .foregroundColor(.red)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                            }.buttonStyle(.plain)

                            Button {
                                Task {
                                    await client.postAndWait("resume")
                                    try? await Task.sleep(for: .seconds(0.8))
                                    await client.postAndWait("connect")
                                }
                            } label: {
                                Text("连接")
                                    .font(.caption2).fontWeight(.medium)
                                    .padding(.horizontal, 12).padding(.vertical, 4)
                                    .background(Color.green.opacity(0.15))
                                    .foregroundColor(.green)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(tilePadding(tile.size))
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(WgTheme.cardBg)
            .clipShape(RoundedRectangle(cornerRadius: WgTheme.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius).stroke(WgTheme.cardBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // --- 导航小卡（日志/关于）---
    private func navTile(_ tile: TileData, isSelected: Bool) -> some View {
        Button {
            switch tile.kind {
            case .logs: withAnimation(.easeInOut(duration: 0.15)) { selection = .logs }
            case .about: withAnimation(.easeInOut(duration: 0.15)) { selection = .about }
            default: break
            }
        } label: {
            VStack(spacing: tile.size == .small ? 4 : 8) {
                HStack {
                    Image(systemName: tile.kind.icon)
                        .font(.system(size: tileSizeIcon(tile.size) - 4))
                        .foregroundStyle(isSelected ? WgTheme.accent : .secondary.opacity(0.7))
                    Spacer()
                }
                HStack {
                    Text(tile.kind.title)
                        .font(tile.size == .small ? .subheadline : (tile.size == .medium ? .body : .title3))
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundStyle(isSelected ? WgTheme.accent : .secondary)
                    Spacer()
                }

                // 中尺寸以上显示描述
                if tile.size != .small {
                    HStack {
                        Text(tile.kind == .logs ? "查看运行日志" : "关于 WgSense")
                            .font(.caption).foregroundStyle(.tertiary)
                        Spacer()
                    }
                }
            }
            .padding(tilePadding(tile.size))
            .frame(minHeight: tileNavMinHeight(tile.size), maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: WgTheme.cardRadius)
                .fill(isSelected ? WgTheme.accent.opacity(0.1) : WgTheme.cardBg))
            .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius)
                .stroke(isSelected ? WgTheme.accent.opacity(0.25) : WgTheme.cardBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// 中/大尺寸日志磁贴：显示滚动日志内容
    private func logContentTile(_ tile: TileData) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 标题栏
            HStack(spacing: 6) {
                Image(systemName: "scroll")
                    .font(.system(size: tileSizeIcon(tile.size) - 4))
                    .foregroundStyle(.secondary)
                Text("日志")
                    .font(tile.size == .medium ? .body : .title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.white.opacity(0.9))
                Spacer()

                // 条目数
                Text("\(client.logLines.count)条")
                    .font(.caption2).monospacedDigit()
                    .foregroundColor(Color(.tertiaryLabelColor))
            }
            .padding(.bottom, 8)

            Divider().opacity(0.15)

            // 滚动日志区域
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: tile.size == .large) {
                    VStack(alignment: .leading, spacing: tile.size == .large ? 3 : 2) {
                        ForEach(client.logLines) { line in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.gray.opacity(0.25))
                                    .frame(width: 4, height: 4)
                                    .padding(.top, 5)
                                Text(line.text)
                                    .font(.system(size: tile.size == .medium ? 10 : 11))
                                    .foregroundColor(.white.opacity(0.55))
                                    .lineLimit(tile.size == .large ? 2 : 1)
                                    .id(line.id)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.top, 8)
                    .padding(.horizontal, 4)
                }
                .onChange(of: client.logLines.count) { _, _ in
                    if let last = client.logLines.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .padding(tilePadding(tile.size))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WgTheme.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: WgTheme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius).stroke(WgTheme.cardBorder, lineWidth: 1))
        .task {
            await client.fetchLogs(n: 30)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await client.fetchLogs(n: 30)
            }
        }
        .modifier(EditShakeModifier(isShaking: isEditMode && draggedItem?.id != tile.id))
    }

    /// navTile 最小高度
    private func tileNavMinHeight(_ size: TileSize) -> CGFloat {
        switch size {
        case .small: return 0
        case .medium: return 80
        case .large: return 120
        }
    }

    // --- 连接面板（内容随尺寸自适应）---
    private func connectionTile(_ tile: TileData) -> some View {
        VStack(alignment: .leading, spacing: tile.size == .small ? 4 : 6) {
            // 第一行：标题 + 状态点
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down.circle")
                    .font(.system(size: tileSizeIcon(tile.size) - 6))
                    .foregroundStyle(isConnected ? .cyan : .secondary)
                Text("连接")
                    .font(tile.size == .small ? .subheadline : (tile.size == .medium ? .body : .title3))
                    .fontWeight(.medium)
                Spacer()
                Circle().fill(isConnected ? Color.green : Color.gray.opacity(0.3))
                    .frame(width: 6, height: 6)
            }

            // 第二行：↑/↓ 速度
            HStack(spacing: 10) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.up").font(.system(size: 9))
                    Text(formatSpeed(client.traffic?.tx_speed ?? 0))
                        .font(.caption2.monospacedDigit())
                }
                HStack(spacing: 3) {
                    Image(systemName: "arrow.down").font(.system(size: 9))
                    Text(formatSpeed(client.traffic?.rx_speed ?? 0))
                        .font(.caption2.monospacedDigit())
                }
                .foregroundStyle(.secondary)
                Spacer()
                if tile.size == .large {
                    // 大尺寸显示累计流量
                    Text("↓ \(formatSize(client.traffic?.rx_bytes ?? 0))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(isConnected ? .primary : .secondary)

            // 中尺寸：增加一行状态文本（无 divider）
            if tile.size == .medium || tile.size == .large {
                Text(isConnected ? "已建立隧道" : "未连接")
                    .font(.system(size: 10))
                    .foregroundStyle(isConnected ? .green : .secondary)
            }

            // 大尺寸：详细信息
            if tile.size == .large {
                if let s = client.status {
                    connDetailRow("Profile", value: s.service.isEmpty ? "无" : s.service)
                    connDetailRow("守护", value: guardRunning ? "运行中" : "暂停")
                }
            }
        }
        .padding(tilePadding(tile.size))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WgTheme.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: WgTheme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius).stroke(WgTheme.cardBorder, lineWidth: 1))
        .task(id: UUID()) {
            await client.fetchTraffic()
            // 持续刷新流量
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await client.fetchTraffic()
            }
        }
    }

    private func connDetailRow(_ label: String, value: String, color: Color? = nil) -> some View {
        HStack {
            Text(label).font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Text(value).font(.caption2.monospacedDigit()).foregroundStyle(color ?? .secondary)
        }
    }

    // MARK: - 通用控制卡片组件（带 Toggle）

    private func controlTile(
        tile: TileData, icon: String, color: Color,
        subtitle: String, isOn: Bool,
        toggleAction: @escaping () -> Void,
        onTap: @escaping () -> Void
    ) -> some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Image(systemName: icon)
                        .font(.system(size: tileSizeIcon(tile.size), weight: .light))
                        .foregroundStyle(isOn ? color : .secondary.opacity(0.5))
                    Spacer()
                    if !isEditMode {
                        Toggle("", isOn: Binding.constant(isOn))
                            .labelsHidden()
                            .toggleStyle(PillToggleStyle(activeColor: color))
                            .fixedSize()
                            .allowsHitTesting(true)
                            .simultaneousGesture(TapGesture().onEnded { _ in toggleAction() })
                    }
                }
                if tile.size != .small { Divider().opacity(0.15) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(tile.kind.title)
                        .font(tile.size == .small ? .subheadline : .body)
                        .fontWeight(.semibold)
                    Text(subtitle)
                        .font(tile.size == .small ? .caption2 : .caption)
                        .foregroundStyle(isOn ? color : .secondary)

                    // 中尺寸：显示状态摘要行
                    if tile.size == .medium {
                        HStack(spacing: 6) {
                            Circle().fill(isOn ? color : Color.gray.opacity(0.3))
                                .frame(width: 6, height: 6)
                            Text(isOn ? "运行中" : "已停止")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                            Spacer()
                        }
                    }

                    // 大尺寸：显示操作按钮
                    if tile.size == .large {
                        HStack(spacing: 12) {
                            Button { Task { await client.post("disconnect") } } label: {
                                Text("断开")
                                    .font(.caption2).fontWeight(.medium)
                                    .padding(.horizontal, 10).padding(.vertical, 3)
                                    .background(Color.red.opacity(0.12)).foregroundColor(.red)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }.buttonStyle(.plain)
                            Button {
                                Task {
                                    await client.postAndWait("resume")
                                    try? await Task.sleep(for: .seconds(0.8))
                                    await client.postAndWait("connect")
                                }
                            } label: {
                                Text("连接")
                                    .font(.caption2).fontWeight(.medium)
                                    .padding(.horizontal, 10).padding(.vertical, 3)
                                    .background(Color.green.opacity(0.12)).foregroundColor(.green)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(tilePadding(tile.size))
            .frame(minHeight: tileMinHeight(tile.size), maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: WgTheme.cardRadius)
                .fill(isOn ? color.opacity(0.07) : WgTheme.cardBg))
            .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius)
                .stroke(isOn ? color.opacity(0.13) : WgTheme.cardBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 动作卡片组件（带执行按钮）

    private func actionTile(
        tile: TileData, icon: String, color: Color,
        subtitle: String, actionLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .font(.system(size: tileSizeIcon(tile.size), weight: .light))
                    .foregroundStyle(color)
                Spacer()
                if !isEditMode {
                    Button(action: action) {
                        Text(actionLabel)
                            .font(.caption2).fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11).padding(.vertical, 4)
                            .background(color).clipShape(Capsule())
                    }.buttonStyle(.plain)
                }
            }
            if tile.size != .small { Divider().opacity(0.15) }
            VStack(alignment: .leading, spacing: 2) {
                Text(tile.kind.title)
                    .font(tile.size == .small ? .subheadline : .body)
                    .fontWeight(.semibold)
                Text(subtitle)
                    .font(tile.size == .small ? .caption2 : .caption)
                    .foregroundStyle(.secondary)

                // 中尺寸：显示快捷操作
                if tile.size == .medium {
                    HStack(spacing: 6) {
                        Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(.tertiary)
                        Text("\(client.pauseMinutes)分钟")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                    }
                }

                // 大尺寸：时长选择器
                if tile.size == .large {
                    HStack(spacing: 8) {
                        Text("暂停时长:")
                            .font(.caption2).foregroundStyle(.tertiary)
                        Picker("", selection: $client.pauseMinutes) {
                            ForEach([1, 5, 10, 30, 60], id: \.self) { m in
                                Text("\(m) 分钟").tag(m)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 100)
                    }
                }
            }
        }
        .padding(tilePadding(tile.size))
        .frame(minHeight: actionTileMinHeight(tile.size), maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: WgTheme.cardRadius).fill(WgTheme.cardBg))
        .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius).stroke(WgTheme.cardBorder, lineWidth: 1))
    }

    // MARK: - 尺寸辅助函数

    /// 图标大小
    private func tileSizeIcon(_ size: TileSize) -> CGFloat {
        switch size {
        case .small: return 20
        case .medium: return 26
        case .large: return 32
        }
    }

    /// 内边距
    private func tilePadding(_ size: TileSize) -> CGFloat {
        switch size {
        case .small: return 10
        case .medium: return 14
        case .large: return 16
        }
    }

    /// 最小高度（control/action 磁贴）
    private func tileMinHeight(_ size: TileSize) -> CGFloat {
        switch size {
        case .small: return 0   // 由外层 tileCell 控制 (88)
        case .medium: return 0  // 由外层 tileCell 控制 (112)
        case .large: return 140
        }
    }

    /// 格式化网速（bytes/s → 可读字符串）
    private func formatSpeed(_ bytesPerSec: Double) -> String {
        let bps = bytesPerSec
        if bps < 1024 { return String(format: "%.0f B/s", bps) }
        if bps < 1024 * 1024 { return String(format: "%.1f KB/s", bps / 1024) }
        if bps < 1024 * 1024 * 1024 { return String(format: "%.1f MB/s", bps / (1024*1024)) }
        return String(format: "%.1f GB/s", bps / (1024*1024*1024))
    }

    private func formatSize(_ bytes: UInt64) -> String {
        let b = Double(bytes)
        if b < 1024 { return String(format: "%.0f B", b) }
        if b < 1024 * 1024 { return String(format: "%.1f KB", b / 1024) }
        if b < 1024 * 1024 * 1024 { return String(format: "%.1f MB", b / (1024*1024)) }
        return String(format: "%.2f GB", b / (1024*1024*1024))
    }

    /// actionTile 的最小高度
    private func actionTileMinHeight(_ size: TileSize) -> CGFloat {
        switch size {
        case .small: return 0
        case .medium: return 0
        case .large: return 130
        }
    }

    // MARK: - 编辑模式覆盖层

    @ViewBuilder
    private func editOverlay(_ tile: TileData) -> some View {
        HStack(spacing: 4) {
            // 删除按钮
            Button {
                withAnimation(.spring(response: 0.3)) {
                    tiles.removeAll { $0.id == tile.id }
                }
            } label: {
                Image(systemName: "minus.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.red.opacity(0.75))
                    .background(Circle().fill(Color.black.opacity(0.4)))
            }.buttonStyle(.plain)

            // 尺寸切换按钮
            Button {
                withAnimation(.spring(response: 0.3)) {
                    let next: TileSize
                    switch tile.size {
                    case .small: next = .medium
                    case .medium: next = .large
                    case .large: next = .small
                    }
                    if let idx = tiles.firstIndex(where: { $0.id == tile.id }) {
                        tiles[idx].size = next
                    }
                }
            } label: {
                Image(systemName: tile.size == .large ? "arrow.down.left.and.arrow.up.right" : "arrow.up.right.and.arrow.down.left")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.4)))
            }.buttonStyle(.plain)
        }
        .transition(.opacity.combined(with: .scale))
        .padding(6)
    }

    // MARK: - 磁贴网格（手动行打包 + VStack/HStack，medium/large 独占一行）

    private var tileGridContent: some View {
        let rows = buildTileRows()
        return VStack(spacing: WgTheme.tileGap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                if !row.isEmpty {
                    // 单个 small 磁贴需要占位符保持半宽
                    let isSingleSmall = row.count == 1 && row[0].size == .small

                    HStack(spacing: WgTheme.tileGap) {
                        if isSingleSmall {
                            tileCell(row[0])
                            Color.clear  // 占位，保持 small 为半宽
                        } else {
                            ForEach(row) { tile in
                                tileCell(tile)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, WgTheme.tileGap)
        .padding(.top, WgTheme.tileGap)
        .padding(.bottom, WgTheme.tileGap)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: tiles.map { $0.kind })
        .padding(.horizontal, 12)
        .padding(.top, 8)
        // 空白处点击退出编辑
        .onTapGesture {
            if isEditMode {
                withAnimation(.spring(response: 0.35)) { isEditMode = false }
            }
        }
        // 空白处长按进入编辑模式
        .overlay(alignment: .bottom) {
            // 底部操作栏
            if !isEditMode {
                // 非编辑模式：只显示"长按空白处编辑"
                Button {
                    withAnimation(.spring(response: 0.35)) { isEditMode = true }
                } label: {
                    Text("长按空白处编辑")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary.opacity(0.5))
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 1.5).onEnded { _ in
                        withAnimation(.spring(response: 0.35)) { isEditMode = true }
                    }
                )
            } else {
                // 编辑模式：添加按钮 + 设置入口 + 退出提示
                HStack(spacing: 8) {
                    // 添加磁贴（收纳进编辑模式）
                    Button { showAddSheet = true } label: {
                        Label("添加磁贴", systemImage: "plus.circle.fill")
                            .font(.caption2).foregroundStyle(WgTheme.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(WgTheme.accent.opacity(0.1)))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(WgTheme.accent.opacity(0.25), lineWidth: 1))
                    }.buttonStyle(.plain)

                    // 设置图标（从 tab 栏挪到编辑栏）
                    Button {
                        selection = .settings
                        withAnimation(.spring(response: 0.35)) { isEditMode = false }
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .padding(6)
                            .background(Circle().fill(Color.white.opacity(0.06)))
                    }.buttonStyle(.plain)

                    Spacer()

                    Text("点击退出编辑")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary.opacity(0.5))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        // 磁贴 Popover 菜单
        .popover(item: $contextMenuTile) { tile in
            tileMenuPopover(tile)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: tiles.map(\.size))
    }

    /// 单个磁贴单元格（三种尺寸模式各自固定物理尺寸）
    @ViewBuilder
    private func tileCell(_ tile: TileData) -> some View {
        Group {
            if tile.size == .small {
                cellBody(tile)
                    .frame(width: WgTheme.tileX, height: WgTheme.tileY)
                    .clipped()
            } else if tile.size == .medium {
                cellBody(tile)
                    .frame(width: WgTheme.tileX * 2 + WgTheme.tileGap, height: WgTheme.tileY)
                    .clipped()
            } else {
                cellBody(tile)
                    .frame(width: WgTheme.tileX * 2 + WgTheme.tileGap, height: WgTheme.tileY * 2 + WgTheme.tileGap)
                    .clipped()
            }
        }
        .contextMenu { tileContextMenu(tile) }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 1.5).onEnded { _ in
                    contextMenuTile = tile
                    contextMenuAnchor = CGPoint(x: 100, y: 50)
                }
            )
    }

    /// 单元格内部内容（编辑/正常双模式）
    @ViewBuilder
    private func cellBody(_ tile: TileData) -> some View {
        if isEditMode {
            TileDragContainer(
                tile: tile,
                isEditMode: true,
                isBeingDragged: draggedItem?.id == tile.id
            ) {
                tileContent(tile)
            }
            .contentShape(Rectangle())
            .onDrag {
                draggedItem = tile
                return NSItemProvider(object: "\(tileIndex(tile))" as NSString)
            }
            .dropDestination(for: String.self) { _, _ in
                guard let dropped = draggedItem,
                      let srcIdx = tiles.firstIndex(where: { $0.id == dropped.id }),
                      let dstIdx = tiles.firstIndex(where: { $0.id == tile.id }),
                      srcIdx != dstIdx else {
                    draggedItem = nil
                    return false
                }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                    tiles.move(fromOffsets: IndexSet(integer: srcIdx),
                               toOffset: dstIdx > srcIdx ? dstIdx + 1 : dstIdx)
                }
                draggedItem = nil
                return true
            }
        } else {
            // 正常模式：纯 SwiftUI 视图，不用 NSViewRepresentable 包裹（避免破坏 HStack 均分）
            TileDragContainer(
                tile: tile,
                isEditMode: false,
                isBeingDragged: false
            ) {
                tileContent(tile)
            }
        }
    }

    /// 磁贴右键菜单内容（三档尺寸）
    @ViewBuilder
    private func tileContextMenu(_ tile: TileData) -> some View {
        if tile.size != .small {
            Button { resizeTile(tile, to: .small) }
            label: { Label("小 (1 格)", systemImage: "square") }
        }
        if tile.size != .medium {
            Button { resizeTile(tile, to: .medium) }
            label: { Label("中 (2 格)", systemImage: "rectangle") }
        }
        if tile.size != .large {
            Button { resizeTile(tile, to: .large) }
            label: { Label("大 (4 格)", systemImage: "rectangle.3.groupfill") }
        }

        Divider()

        Button(role: .destructive) {
            withAnimation(.spring(response: 0.3)) {
                tiles.removeAll { $0.id == tile.id }
            }
        } label: { Label("移除磁贴", systemImage: "trash") }
    }

    /// 调整磁贴尺寸（带弹性动画）
    private func resizeTile(_ tile: TileData, to newSize: TileSize) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            if let idx = tiles.firstIndex(where: { $0.id == tile.id }) {
                tiles[idx].size = newSize
            }
        }
    }

    /// 磁贴 Popover 菜单
    @ViewBuilder
    private func tileMenuPopover(_ tile: TileData) -> some View {
        VStack(spacing: 0) {
            if tile.size != .small {
                menuRow("小 (1 格)", icon: "square") { resizeTile(tile, to: .small); contextMenuTile = nil }
            }
            if tile.size != .medium {
                menuRow("中 (2 格)", icon: "rectangle") { resizeTile(tile, to: .medium); contextMenuTile = nil }
            }
            if tile.size != .large {
                menuRow("大 (4 格)", icon: "rectangle.3.groupfill") { resizeTile(tile, to: .large); contextMenuTile = nil }
            }
            Divider().padding(.horizontal, 12)
            menuRow("移除磁贴", icon: "trash", destructive: true) {
                withAnimation(.spring(response: 0.3)) {
                    tiles.removeAll { $0.id == tile.id }
                }
                contextMenuTile = nil
            }
        }
        .padding(.vertical, 4)
        .frame(width: 170)
    }

    private func menuRow(_ title: String, icon: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13))
                    .foregroundStyle(destructive ? .red : .primary)
                Text(title).font(.subheadline)
                    .foregroundStyle(destructive ? .red : .primary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(destructive ? Color.red.opacity(0.08) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    func tileIndex(_ t: TileData) -> Int {
        tiles.firstIndex(where: { $0.id == t.id }) ?? 0
    }

    /// 网格布局引擎：2列网格，支持 small(1格)/medium(2格全宽)/large(4格=2行)
    /// 手动行打包：small 两个并排，medium/large 独占一行（只占 1 列宽）
    func buildTileRows() -> [[TileData]] {
        var result: [[TileData]] = []
        var i = 0

        while i < tiles.count {
            let tile = tiles[i]

            switch tile.size {
            case .small:
                // 尝试和下一个 small 并排
                if i + 1 < tiles.count && tiles[i + 1].size == .small {
                    result.append([tile, tiles[i + 1]])
                    i += 2
                } else {
                    // 单个 small 独占一行（渲染时限制为半宽）
                    result.append([tile])
                    i += 1
                }

            case .medium:
                result.append([tile])
                i += 1

            case .large:
                result.append([tile])
                result.append([])  // large 占用的第二行
                i += 1
            }
        }

        return result.isEmpty ? [[]] : result
    }
}

// MARK: - 原生风格 Toggle 开关

/// iOS UISwitch 风格的开关组件（纯展示，点击由外层 Button 处理）
struct ToggleSwitch: View {
    let isOn: Bool
    var tintColor: Color = .green

    private let trackWidth: CGFloat = 44
    private let trackHeight: CGFloat = 26
    private let thumbSize: CGFloat = 22
    private let padding: CGFloat = 2

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            // 轨道背景
            Capsule()
                .fill(isOn ? tintColor.opacity(0.3) : Color.gray.opacity(0.25))
                .frame(width: trackWidth, height: trackHeight)

            // 圆形滑块（thumb）
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                .frame(width: thumbSize, height: thumbSize)
                .padding(padding)
        }
        .animation(.easeInOut(duration: 0.22), value: isOn)
    }
}

// MARK: - iOS 抖动动画修饰器

struct EditShakeModifier: ViewModifier {
    let isShaking: Bool
    @State private var rotation: Double = 0
    @State private var shakeTimer: Timer?

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(rotation))
            .onChange(of: isShaking) { _, newValue in
                if newValue {
                    startShaking()
                } else {
                    stopShaking()
                }
            }
            .onAppear {
                // 关键修复：如果初始就是 shaking 状态（编辑模式直接进入），onAppear 补充启动
                if isShaking && shakeTimer == nil {
                    startShaking()
                }
            }
            .onDisappear { stopShaking() }
    }

    func startShaking() {
        stopShaking()
        shakeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [self] _ in
            withAnimation(.easeInOut(duration: 0.08)) {
                rotation = Double.random(in: -2...2)
            }
        }
    }

    func stopShaking() {
        shakeTimer?.invalidate()
        shakeTimer = nil
        withAnimation(.linear(duration: 0.15)) { rotation = 0 }
    }
}

// MARK: - macOS 触控板重按（Force Press）容器
/// 将 ForcePressNSView 作为底层容器接收压力事件，SwiftUI 内容作为 NSHostingView 子视图
/// 解决 background/overlay 方式 NSView 无法正确接收触控板压力事件的问题
struct ForcePressContainer<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ForcePressNSViewRepresentable(action: action, content: content())
    }
}

private struct ForcePressNSViewRepresentable<Content: View>: NSViewRepresentable {
    let action: () -> Void
    let content: Content

    func makeNSView(context: Context) -> NSView {
        let containerView = ForcePressContainerNSView()
        containerView.action = action

        let hostingView = NSHostingView(rootView: content)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
        ])

        return containerView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let container = nsView as? ForcePressContainerNSView,
              let hosting = container.subviews.first as? NSHostingView<Content> else { return }
        hosting.rootView = content
    }
}

/// 轻量版 ForcePress NSView（无 Content 泛参，用于 overlay 层，不干扰布局）
private struct ForcePressOverlayNSView: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> ForcePressContainerNSView {
        let view = ForcePressContainerNSView()
        view.action = action
        return view
    }

    func updateNSView(_ nsView: ForcePressContainerNSView, context: Context) {
        nsView.action = action
    }
}

/// 底层 NSView：接收触控板压力事件（深按/二段按），SwiftUI 内容在其上方正常交互
private class ForcePressContainerNSView: NSView {
    var action: () -> Void = {}
    private var hasFired = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // 配置深按（二段按）压力行为
        pressureConfiguration = .init(pressureBehavior: .primaryDeepClick)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func pressureChange(with event: NSEvent) {
        guard !hasFired else { return }
        if event.stage == 2 {
            // stage == 2 = 二段按压（用力深按）
            hasFired = true
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.hasFired = false
            }
        }
    }
}

// MARK: - 药丸开关样式

struct PillToggleStyle: ToggleStyle {
    let activeColor: Color

    func makeBody(configuration: Configuration) -> some View {
        Capsule()
            .fill(configuration.isOn ? activeColor : Color.secondary.opacity(0.35))
            .frame(width: 44, height: 24)
            .overlay(
                Circle()
                    .fill(.white).frame(width: 19, height: 19)
                    .shadow(color: .black.opacity(0.15), radius: 1, x: 0, y: 0.5)
                    .offset(x: configuration.isOn ? 11.5 : -11.5)
            )
            .animation(.spring(response: 0.25, dampingFraction: 0.85), value: configuration.isOn)
            .onTapGesture {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) { configuration.isOn.toggle() }
            }
    }
}

// MARK: - 添加磁贴 Sheet

struct AddTileSheet: View {
    let existingKinds: [TileKind]
    let onSelect: (TileKind) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("添加磁贴").font(.headline).fontWeight(.semibold)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
            .padding()

            Divider().opacity(0.3)

            let available = TileKind.allCases.filter { !existingKinds.contains($0) }
            if available.isEmpty {
                Text("所有磁贴已添加").foregroundColor(.secondary).padding()
            } else {
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible())
                ], spacing: 10) {
                    ForEach(available) { kind in
                        Button { onSelect(kind) } label: {
                            VStack(spacing: 8) {
                                Image(systemName: kind.icon)
                                    .font(.system(size: 24))
                                    .foregroundStyle(kind.activeColor)
                                Text(kind.title).font(.subheadline).fontWeight(.medium)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(16)
                            .background(RoundedRectangle(cornerRadius: 10).fill(WgTheme.cardBg))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(WgTheme.cardBorder, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        }
        .frame(width: 320, height: availableKinds.isEmpty ? 200 : nil)
    }

    private var availableKinds: [TileKind] { TileKind.allCases.filter { !existingKinds.contains($0) } }
}

// MARK: - 关于页

struct AboutView: View {
    @EnvironmentObject var client: DaemonClient

    var body: some View {
        VStack(alignment: .leading, spacing: WgTheme.spacing) {
            Text("关于").font(.title2).fontWeight(.semibold)
            VStack(spacing: 16) {
                HStack(spacing: 16) {
                    Image(systemName: "shield.lefthalf.filled").font(.system(size: 40)).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("WgSense").font(.title2).fontWeight(.bold)
                        Text("v0.1-alpha").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                Divider().opacity(0.3)
                aboutRow("定位", "跨平台网络工具套件")
                aboutRow("核心", "WireGuard 客户端 + 智能管理")
                aboutRow("协议", "Apache-2.0 开源")
                aboutRow("平台", "macOS / Windows / Linux / iOS / Android")
                Divider().opacity(0.3)
                if let s = client.status {
                    aboutRow("Daemon", s.state == "Connected" ? "运行中" : "未运行")
                    aboutRow("Profile", s.service.isEmpty ? "无" : s.service)
                }
            }
            .padding(20)
            .background(WgTheme.cardBg)
            .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius).stroke(WgTheme.cardBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: WgTheme.cardRadius))
            Spacer()
        }
    }

    private func aboutRow(_ l: String, _ v: String) -> some View {
        HStack { Text(l).font(.subheadline).foregroundStyle(.secondary); Spacer(); Text(v).font(.subheadline).fontWeight(.medium) }
        .padding(.vertical, 4)
    }
}

// MARK: - 磁贴拖拽容器（编辑模式简化版，无内部按钮冲突）

struct TileDragContainer<Content: View>: View {
    let tile: TileData
    let isEditMode: Bool
    let isBeingDragged: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        if isEditMode {
            // 编辑模式：简化卡片（无内部 Button），确保拖拽不冲突
            simplifiedTile
                .opacity(isBeingDragged ? 0.35 : 1.0)
                .animation(.spring(response: 0.3), value: isBeingDragged)
                .modifier(EditShakeModifier(isShaking: true))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "line.horizontal.3")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                        .padding(6)
                }
        } else {
            // 正常模式：完整交互内容
            content()
        }
    }

    // 编辑模式下的简化卡片（纯展示 + 拖拽手柄）
    private var simplifiedTile: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: tile.kind.icon)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(tile.kind.activeColor)
                Spacer()
            }
            HStack {
                Text(tile.kind.title)
                    .font(.subheadline).fontWeight(.semibold)
                Spacer()
                // 尺寸标签
                Text(sizeLabel(tile.size))
                    .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06)))
            }
            if tile.size == .medium || tile.size == .large {
                Divider().opacity(0.2)
                HStack {
                    Image(systemName: "hand.draw")
                        .font(.caption2)
                    Text("拖拽排序")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: tile.size == .large ? 200 : 96, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: WgTheme.cardRadius).fill(WgTheme.cardBg))
        .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius).stroke(WgTheme.cardBorder.opacity(0.5), lineWidth: 1))
    }

    private func sizeLabel(_ size: TileSize) -> String {
        switch size {
        case .small: return "1格"
        case .medium: return "2格"
        case .large: return "4格"
        }
    }
}

extension Notification.Name {
    static let wgsenseDeleteProfile = Notification.Name("wgsenseDeleteProfile")
}

// MARK: - 接收页（独立视图）
struct TransferReceiveView: View {
    @EnvironmentObject var client: DaemonClient
    @State private var togglingReceive = false
    @State private var resolvingRequestID: String?
    @State private var startingDaemon = false

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("文件接收")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)
                    Text("LocalSend 兼容接收服务")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if let state = client.transferState {
                    HStack(spacing: 10) {
                        HStack(spacing: 6) {
                            Circle().fill(state.running ? Color.green : Color.red).frame(width: 10, height: 10)
                            Text(state.running ? "运行中" : "已停止").font(.callout.weight(.medium))
                                .foregroundStyle(state.running ? .green : .red)
                        }
                        Toggle("", isOn: Binding(
                            get: { client.transferState?.running ?? false },
                            set: { enabled in
                                Task {
                                    togglingReceive = true
                                    let ok = await client.setTransferReceiveEnabled(enabled)
                                    if !ok { await client.fetchTransferState() }
                                    togglingReceive = false
                                }
                            }
                        ))
                        .labelsHidden()
                        .disabled(togglingReceive)
                        if togglingReceive { ProgressView().controlSize(.small) }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 8).fill((state.running ? Color.green : Color.red).opacity(0.1)))
                }
            }
            Divider().opacity(0.15)

            if let state = client.transferState {
                VStack(alignment: .leading, spacing: 16) {
                    receiveInfoRow("设备别名", value: state.alias)
                    Divider().opacity(0.1)
                    HStack { receiveInfoRow("端口", value: "\(state.port)"); Spacer(); receiveInfoRow("保存目录", value: URL(fileURLWithPath: state.downloads).lastPathComponent) }
                    Divider().opacity(0.1)
                    receiveInfoRow("下载路径", value: state.downloads)
                }
                .padding(20)
                .background(RoundedRectangle(cornerRadius: WgTheme.cardRadius).fill(WgTheme.cardBg))
                .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius).stroke(WgTheme.cardBorder, lineWidth: 1))
            } else {
                HStack(spacing: 12) {
                    if client.transferError == nil { ProgressView() }
                    else { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                    Text(client.transferError ?? "正在连接 daemon...").font(.body).foregroundStyle(.secondary)
                    Spacer()
                    if client.transferError != nil {
                        Button(startingDaemon ? "正在启动..." : "启动后台服务") {
                            Task {
                                startingDaemon = true
                                _ = await client.startDaemonForTransfer()
                                startingDaemon = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(startingDaemon)
                    }
                }
                .frame(maxWidth: .infinity).padding()
                .background(RoundedRectangle(cornerRadius: WgTheme.cardRadius).fill(WgTheme.cardBg))
                .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius).stroke(WgTheme.cardBorder, lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("待接收").font(.headline.weight(.semibold))
                    Spacer()
                    if let count = client.transferState?.pending.count, count > 0 {
                        Text("\(count)").font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(WgTheme.accent))
                    }
                }
                if let pending = client.transferState?.pending, !pending.isEmpty {
                    ForEach(pending) { pendingRequestRow($0) }
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "tray.and.arrow.down").foregroundStyle(.tertiary)
                        Text("暂无待确认的传输").font(.callout).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: WgTheme.cardRadius).fill(WgTheme.cardBg))
                    .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius).stroke(WgTheme.cardBorder, lineWidth: 1))
                }
            }

            if let active = client.transferState?.active, !active.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("接收中").font(.headline.weight(.semibold))
                    ForEach(active) { activeTransferRow($0) }
                }
            }

            if let history = client.transferState?.history, !history.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("最近接收").font(.headline.weight(.semibold))
                    ForEach(Array(history.prefix(5))) { historyTransferRow($0) }
                }
            }
            Spacer()
        }
        .padding(28)
        .task {
            while !Task.isCancelled {
                await client.fetchTransferState()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func receiveInfoRow(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.tertiary)
            Text(value).font(.body.weight(.medium)).foregroundStyle(.primary)
        }
    }

    private func pendingRequestRow(_ request: DaemonClient.TransferPendingRequest) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "desktopcomputer.and.arrow.down")
                .font(.system(size: 22)).foregroundStyle(WgTheme.accent)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(request.alias).font(.body.weight(.semibold))
                Text("\(request.files.count) 个文件 · \(formattedBytes(request.totalSize)) · \(request.ip)")
                    .font(.caption).foregroundStyle(.secondary)
                Text(request.files.prefix(3).map(\.name).joined(separator: "、"))
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            if resolvingRequestID == request.id {
                ProgressView().controlSize(.small).frame(width: 72)
            } else {
                Button(role: .destructive) { resolve(request, accepted: false) } label: {
                    Image(systemName: "xmark").frame(width: 20, height: 20)
                }
                .buttonStyle(.bordered).help("拒绝")
                Button { resolve(request, accepted: true) } label: {
                    Label("接受", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: WgTheme.cardRadius).fill(WgTheme.cardBg))
        .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius).stroke(WgTheme.cardBorder, lineWidth: 1))
    }

    private func resolve(_ request: DaemonClient.TransferPendingRequest, accepted: Bool) {
        resolvingRequestID = request.id
        Task {
            _ = await client.resolveTransferRequest(request.id, accepted: accepted)
            resolvingRequestID = nil
        }
    }

    private func activeTransferRow(_ progress: DaemonClient.TransferFileProgress) -> some View {
        let total = max(progress.totalBytes, 1)
        let fraction = min(max(Double(progress.doneBytes) / Double(total), 0), 1)
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Image(systemName: "arrow.down.doc.fill").foregroundStyle(WgTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(progress.fileName).font(.body.weight(.medium)).lineLimit(1)
                    Text("来自 \(progress.sender) · \(progress.senderIP)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(fraction * 100))%")
                    .font(.caption.monospacedDigit().weight(.medium)).foregroundStyle(.secondary)
            }
            ProgressView(value: fraction).animation(.easeOut(duration: 0.18), value: progress.doneBytes)
            HStack { Text(formattedBytes(progress.doneBytes)); Spacer(); Text(formattedBytes(progress.totalBytes)) }
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: WgTheme.cardRadius).fill(WgTheme.cardBg))
        .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius).stroke(WgTheme.cardBorder, lineWidth: 1))
    }

    private func historyTransferRow(_ progress: DaemonClient.TransferFileProgress) -> some View {
        HStack(spacing: 12) {
            Image(systemName: progress.status == "completed" ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(progress.status == "completed" ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(progress.fileName).font(.callout.weight(.medium)).lineLimit(1)
                Text(progress.status == "completed"
                     ? "\(progress.sender) · \(formattedBytes(progress.doneBytes))"
                     : "\(progress.sender) · \(progress.error ?? "传输失败")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(progress.status == "completed" ? "已完成" : "失败")
                .font(.caption.weight(.medium)).foregroundStyle(progress.status == "completed" ? .green : .orange)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: WgTheme.cardRadius).fill(WgTheme.cardBg))
        .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius).stroke(WgTheme.cardBorder, lineWidth: 1))
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - 发送页（独立视图）
struct TransferSendView: View {
    @EnvironmentObject var client: DaemonClient

    enum SendType: String, CaseIterable {
        case file, folder, text, clipboard
        static var supportedCases: [SendType] { [.file, .folder] }
        var icon: String {
            switch self { case .file: return "doc"; case .folder: return "folder"; case .text: return "text.bubble"; case .clipboard: return "clipboard" }
        }
        var label: String {
            switch self { case .file: return "文件"; case .folder: return "文件夹"; case .text: return "文本"; case .clipboard: return "剪贴板" }
        }
    }

    @State private var sendType: SendType? = nil
    @State private var showFilePicker = false
    @State private var showFolderPicker = false
    @State private var selectedDevice: DaemonClient.TransferDevice?
    @State private var isStartingSend = false
    @State private var lastSendResult: String?
    @State private var isScanning = false
    @State private var showAddDeviceSheet = false
    @State private var addDeviceAddr = ""
    @State private var startingDaemon = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("发送").font(.system(size: 22, weight: .bold)).foregroundStyle(.primary)
                    .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 16)
                Text("发送类型").font(.caption).fontWeight(.medium).foregroundStyle(.tertiary).padding(.horizontal, 20)
                ForEach(SendType.supportedCases, id: \.self) { type in
                    Button { selectSendType(type) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: type.icon).font(.system(size: 16, weight: .medium)).frame(width: 24)
                            Text(type.label).font(.callout); Spacer()
                            if sendType == type { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(WgTheme.accent) }
                        }
                        .foregroundStyle(sendType == type ? WgTheme.accent : .secondary)
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(sendType == type ? WgTheme.accent.opacity(0.12) : Color.clear))
                    }.buttonStyle(.plain)
                }
                Spacer()
                if let result = lastSendResult {
                    Text(result).font(.caption).foregroundStyle(result.contains("失败") || result.contains("未") ? .orange : .green).padding(16).multilineTextAlignment(.center)
                }
            }
            .frame(width: 180).background(WgTheme.sidebarBg)
            Rectangle().fill(WgTheme.cardBorder.opacity(0.5)).frame(width: 1)
            ScrollView { sendContentArea.padding(32) }.background(WgTheme.bg)
        }
        .task {
            await loadInitialData()
            while !Task.isCancelled {
                await client.fetchTransferTasks()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.data, .image, .movie, .audio], allowsMultipleSelection: true) { handleFileSelection($0) }
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { handleFileSelection($0) }
        .sheet(isPresented: $showAddDeviceSheet) { addDeviceSheet }
    }

    // MARK: - 右侧内容区
    @ViewBuilder
    private var sendContentArea: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("目标设备").font(.headline.weight(.semibold)); Spacer()
                    HStack(spacing: 8) {
                        Button { Task { await refreshDevices() } } label: {
                            Image(systemName: "arrow.clockwise").font(.system(size: 13)).foregroundStyle(.secondary)
                                .frame(width: 28, height: 28).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(isScanning).help("刷新设备")
                        Button { Task { await scanSubnetDevices() } } label: {
                            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(.blue)
                                .frame(width: 28, height: 28).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(isScanning).help("扫描局域网设备")
                        Button { showAddDeviceSheet = true } label: {
                            Image(systemName: "plus.circle").font(.system(size: 13)).foregroundStyle(.orange)
                                .frame(width: 28, height: 28).contentShape(Rectangle())
                        }.buttonStyle(.plain).help("手动添加设备")
                    }
                }
                if client.transferDevices.isEmpty && !isScanning { deviceEmptyCard }
                else { LazyVGrid(columns: [GridItem(.flexible(), spacing: 12)], spacing: 12) { ForEach(client.transferDevices) { device in sendDeviceRow(device) } } }
            }
            if let device = selectedDevice { Divider().opacity(0.1); selectedDeviceActions(device) }
            if let active = client.transferSendTasks?.active, !active.isEmpty {
                Divider().opacity(0.1)
                VStack(alignment: .leading, spacing: 12) {
                    Text("发送任务").font(.headline.weight(.semibold))
                    ForEach(active) { activeSendTaskRow($0) }
                }
            }
            if let history = client.transferSendTasks?.history, !history.isEmpty {
                Divider().opacity(0.1)
                VStack(alignment: .leading, spacing: 12) {
                    Text("最近发送").font(.headline.weight(.semibold))
                    ForEach(Array(history.prefix(5))) { sendHistoryRow($0) }
                }
            }
            Spacer()
        }
    }

    private var deviceEmptyCard: some View {
        VStack(spacing: 16) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash").font(.system(size: 48)).foregroundStyle(.quaternary)
            VStack(spacing: 6) {
                Text(client.transferError ?? "暂无发现设备").font(.headline).foregroundStyle(.secondary)
                Text(client.transferError == nil ? "点击上方「扫描」或「+」手动添加隧道内设备的 IP 地址" : "传输功能需要连接到 WgSense daemon")
                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                if client.transferError != nil {
                    Button(startingDaemon ? "正在启动..." : "启动后台服务") {
                        Task {
                            startingDaemon = true
                            _ = await client.startDaemonForTransfer()
                            startingDaemon = false
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(startingDaemon)
                }
            }
        }
        .frame(maxWidth: .infinity).padding(40)
        .background(RoundedRectangle(cornerRadius: WgTheme.cardRadius).fill(WgTheme.cardBg))
        .overlay(
            RoundedRectangle(cornerRadius: WgTheme.cardRadius)
                .stroke(WgTheme.cardBorder, style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
        )
    }

    private func selectedDeviceActions(_ device: DaemonClient.TransferDevice) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(device.alias).font(.body.weight(.semibold))
                if let ip = device.ip { Text(ip).font(.caption).foregroundStyle(.tertiary) }
            }
            Spacer()
            if sendType != nil {
                Button { triggerSend(target: device) } label: {
                    Label(isStartingSend ? "创建中..." : "发送", systemImage: isStartingSend ? "arrow.triangle.2.circlepath" : "paperplane.fill")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(isStartingSend ? AnyShapeStyle(Color.gray.opacity(0.7)) : AnyShapeStyle(Color.white))
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(RoundedRectangle(cornerRadius: 10).fill(isStartingSend ? Color.gray : WgTheme.accent))
                }.disabled(isStartingSend)
            } else { Text("请选择发送类型 →").font(.callout.italic()).foregroundStyle(.tertiary) }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: WgTheme.cardRadius).fill(WgTheme.cardBg))
        .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius).stroke(WgTheme.accent.opacity(0.4), lineWidth: 1))
    }

    // MARK: - 添加设备 Sheet
    private var addDeviceSheet: some View {
        VStack(spacing: 20) {
            Text("添加设备").font(.headline.weight(.bold))
            Text("输入设备的 IP 地址（或 IP:端口）").font(.subheadline).foregroundStyle(.secondary)
            TextField("例如：192.168.200.5 或 192.168.200.5:53317", text: $addDeviceAddr).textFieldStyle(.roundedBorder).font(.body.monospaced()).autocorrectionDisabled()
            HStack(spacing: 12) {
                Button("取消") { showAddDeviceSheet = false; addDeviceAddr = "" }.keyboardShortcut(.escape, modifiers: []).buttonStyle(.bordered)
                Button {
                    let addr = addDeviceAddr.trimmingCharacters(in: .whitespacesAndNewlines); guard !addr.isEmpty else { return }
                    Task {
                        if let _ = await client.addManualDevice(addr: addr) {
                            await MainActor.run { showAddDeviceSheet = false; addDeviceAddr = ""; lastSendResult = "设备已添加"; DispatchQueue.main.asyncAfter(deadline: .now() + 3) { lastSendResult = nil } }
                        } else { await MainActor.run { lastSendResult = "连接失败，检查地址后重试"; DispatchQueue.main.asyncAfter(deadline: .now() + 4) { lastSendResult = nil } } }
                    }
                } label: { Text("添加") }.buttonStyle(.borderedProminent).disabled(addDeviceAddr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("提示：确保目标设备已运行 LocalSend 或 WgSense").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
        }.padding(28).frame(width: 420, height: 280)
    }

    // MARK: - Actions
    private func loadInitialData() async {
        await client.fetchTransferState()
        await client.fetchTransferDevices(timeoutSec: 3)
        await client.fetchTransferTasks()
    }
    private func refreshDevices() async { isScanning = true; await client.fetchTransferDevices(timeoutSec: 5); try? await Task.sleep(for: .seconds(1)); isScanning = false }
    private func scanSubnetDevices() async { isScanning = true; let found = await client.scanSubnet(timeoutSec: 10); try? await Task.sleep(for: .seconds(1)); isScanning = false; if found.isEmpty { lastSendResult = "扫描完成，未发现 LocalSend 设备"; DispatchQueue.main.asyncAfter(deadline: .now() + 4) { lastSendResult = nil } } else { lastSendResult = "扫描发现 \(found.count) 个设备"; DispatchQueue.main.asyncAfter(deadline: .now() + 4) { lastSendResult = nil } } }
    private func selectSendType(_ type: SendType) { withAnimation(.easeInOut(duration: 0.15)) { sendType = type } }
    private func triggerSend(target: DaemonClient.TransferDevice) {
        guard sendType != nil else { return }
        if sendType == .file || sendType == .folder {
            if sendType == .file { showFilePicker = true } else { showFolderPicker = true }
            return
        }
        lastSendResult = "当前版本仅支持发送文件和文件夹"
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else {
            lastSendResult = "选择文件失败"
            return
        }
        guard let target = selectedDevice else { return }
        let paths = urls.map(\.path)
        guard !paths.isEmpty else {
            lastSendResult = "无法获取文件路径"
            return
        }

        isStartingSend = true
        lastSendResult = nil
        Task {
            let success = await client.startFileSend(to: target.id, paths: paths) != nil
            await MainActor.run {
                isStartingSend = false
                lastSendResult = success ? "等待对方确认" : "发送任务创建失败"
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { lastSendResult = nil }
            }
        }
    }

    private func activeSendTaskRow(_ task: DaemonClient.TransferSendTask) -> some View {
        let total = max(task.totalBytes, 1)
        let fraction = min(max(Double(task.doneBytes) / Double(total), 0), 1)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: task.status == "waiting" ? "person.crop.circle.badge.clock" : "paperplane.fill")
                    .font(.system(size: 20)).foregroundStyle(WgTheme.accent).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.deviceAlias).font(.body.weight(.semibold))
                    Text(sendStatusLabel(task.status)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if task.status == "sending" {
                    Text("\(Int(fraction * 100))%").font(.caption.monospacedDigit().weight(.medium)).foregroundStyle(.secondary)
                }
                Button { Task { _ = await client.cancelTransfer(taskID: task.id) } } label: {
                    Image(systemName: "xmark.circle").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).disabled(task.status == "cancelling").help("取消发送")
            }
            ProgressView(value: fraction).animation(.easeInOut(duration: 0.18), value: task.doneBytes)
            HStack {
                Text(task.files.prefix(3).map(\.name).joined(separator: "、")).lineLimit(1)
                Spacer()
                Text("\(formattedSendBytes(task.doneBytes)) / \(formattedSendBytes(task.totalBytes))").monospacedDigit()
            }
            .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: WgTheme.cardRadius).fill(WgTheme.cardBg))
        .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius).stroke(WgTheme.cardBorder, lineWidth: 1))
    }

    private func sendHistoryRow(_ task: DaemonClient.TransferSendTask) -> some View {
        HStack(spacing: 12) {
            Image(systemName: task.status == "completed" ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(task.status == "completed" ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.deviceAlias).font(.callout.weight(.medium)).lineLimit(1)
                Text(task.status == "completed"
                     ? "\(task.completedFiles) 个文件 · \(formattedSendBytes(task.doneBytes))"
                     : task.error ?? sendStatusLabel(task.status))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(sendStatusLabel(task.status)).font(.caption.weight(.medium))
                .foregroundStyle(task.status == "completed" ? .green : .orange)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: WgTheme.cardRadius).fill(WgTheme.cardBg))
        .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius).stroke(WgTheme.cardBorder, lineWidth: 1))
    }

    private func sendStatusLabel(_ status: String) -> String {
        switch status {
        case "preparing": return "正在整理文件"
        case "waiting": return "等待对方确认"
        case "sending": return "发送中"
        case "cancelling": return "正在取消"
        case "completed": return "已完成"
        case "cancelled": return "已取消"
        case "failed": return "失败"
        default: return status
        }
    }

    private func formattedSendBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - 设备行
    private func sendDeviceRow(_ device: DaemonClient.TransferDevice) -> some View {
        HStack(spacing: 10) {
            Button { withAnimation { selectedDevice = device } } label: {
                HStack(spacing: 14) {
                Image(systemName: iconForOS(device.deviceType ?? "")).font(.system(size: 26)).foregroundStyle(colorForOS(device.deviceType ?? ""))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(device.alias).font(.body.weight(.medium)).foregroundStyle(.primary)
                        Text(sourceBadgeLabel(device.source ?? "multicast")).font(.system(size: 9)).foregroundStyle(colorForDeviceSource(device.source ?? "multicast")).padding(.horizontal, 5).padding(.vertical, 1).background(colorForDeviceSource(device.source ?? "multicast").opacity(0.12)).cornerRadius(3)
                    }
                    if let ip = device.ip { Text(ip).font(.caption2).foregroundStyle(.tertiary) }
                }
                Spacer()
                if selectedDevice?.id == device.id { Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(WgTheme.accent) }
                }
            }.buttonStyle(.plain)
            if device.source == "manual" {
                Button {
                    Task {
                        let ok = await client.removeManualDevice(deviceID: device.id)
                        if selectedDevice?.id == device.id { selectedDevice = nil }
                        lastSendResult = ok ? "设备已移除" : "只能移除手动添加的设备"
                    }
                } label: {
                    Image(systemName: "trash").font(.system(size: 13)).foregroundStyle(.red.opacity(0.75))
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }.buttonStyle(.plain).help("移除此手动设备")
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: WgTheme.cardRadius).fill(selectedDevice?.id == device.id ? WgTheme.accent.opacity(0.08) : WgTheme.cardBg).overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius).stroke(selectedDevice?.id == device.id ? WgTheme.accent : WgTheme.cardBorder, lineWidth: 1)))
    }

    private func sourceBadgeLabel(_ source: String) -> String { switch source { case "manual": return "手动"; case "scan": return "扫描"; default: return "多播" } }
    private func colorForDeviceSource(_ source: String) -> Color { switch source { case "manual": return .orange; case "scan": return .blue; default: return .green } }
    private func iconForOS(_ dt: String) -> String { let d = dt.lowercased(); if d.contains("mac") || d.contains("ios") { return "desktopcomputer" }; if d.contains("android") { return "smartphone" }; if d.contains("windows") { return "pc" }; return "laptopcomputer" }
    private func colorForOS(_ dt: String) -> Color { let d = dt.lowercased(); if d.contains("mac") || d.contains("ios") { return .blue }; if d.contains("android") { return .green }; if d.contains("windows") { return .cyan }; return .purple }
}

// MARK: - 设置行组件
private struct SettingsToggleRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        HStack {
            Text(label).font(.body).foregroundStyle(.primary)
            Spacer()
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(WgTheme.accent)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(WgTheme.cardBorder.opacity(0.3)).frame(height: 0.5).padding(.leading, 16)
        }
    }
}

private struct SettingsButtonRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).font(.body).foregroundStyle(.primary)
            Spacer()
            Text(value).font(.body).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(WgTheme.cardBorder.opacity(0.3)).frame(height: 0.5).padding(.leading, 16)
        }
    }
}

private struct SettingsNavRow: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(label).font(.body).foregroundStyle(.primary)
                Spacer()
                Text("打开").font(.body).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Rectangle().fill(WgTheme.cardBorder.opacity(0.3)).frame(height: 0.5).padding(.leading, 16)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Environment Key for DaemonClient

private struct DaemonClientKey: EnvironmentKey {
    @MainActor static let defaultValue = DaemonClient()
}

extension EnvironmentValues {
    var daemonClient: DaemonClient {
        get { self[DaemonClientKey.self] }
        set { self[DaemonClientKey.self] = newValue }
    }
}

// MARK: - Xcode Preview
#Preview("概览页") {
    MainView()
}
