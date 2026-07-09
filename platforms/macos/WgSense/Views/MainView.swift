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
                    case .dashboard: OverviewView()
                    case .wireguard: WireGuardDetailView()
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
    case dashboard, wireguard, settings, logs, about
    var id: String { rawValue }

    var label: String {
        switch self {
        case .dashboard: return "概览"
        case .wireguard: return "WireGuard"
        case .settings: return "设置"
        case .logs: return "日志"
        case .about: return "关于"
        }
    }
}

// MARK: - 磁贴数据模型

enum TileKind: String, CaseIterable, Identifiable, Codable {
    case vpn, guardMode, pause, profile, logs, about, connection
    var id: String { rawValue }

    var title: String {
        switch self {
        case .vpn: return "VPN"
        case .guardMode: return "守护"
        case .pause: return "暂停"
        case .profile: return "Profile"
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
        case .profile: return .orange
        case .logs: return .secondary
        case .about: return .secondary
        case .connection: return .cyan
        }
    }

    /// 默认尺寸：small=1格(半行), medium=2格(全宽), large=4格(全宽两行)
    var defaultSize: TileSize {
        switch self {
        case .connection: return .medium
        default: return .small
        }
    }
}

enum TileSize: String, Codable, CaseIterable {
    case small   // 1 格子（半行）
    case medium  // 2 格子（全宽一行）
    case large   // 4 格子（全宽两行）
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
    private var isConnected: Bool { client.status?.state == "Connected" }
    private var guardRunning: Bool { client.status?.paused == false }

    init(selection: Binding<SidebarTab>) {
        self._selection = selection
        _tiles = State(initialValue: Self.defaultTiles())
    }

    static func defaultTiles() -> [TileData] {
        [
            TileData(kind: .vpn),
            TileData(kind: .guardMode),
            TileData(kind: .pause),
            TileData(kind: .profile),
            TileData(kind: .logs),
            TileData(kind: .about),
            TileData(kind: .connection),
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            tabRow
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
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Tab 行

    private var tabRow: some View {
        let topTabs: [SidebarTab] = [.dashboard, .wireguard, .settings]
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
        Group {
            switch tile.kind {
            case .vpn:
                vpnTile(tile)
            case .guardMode:
                guardTile(tile)
            case .pause:
                pauseTile(tile)
            case .profile:
                profileTile(tile)
            case .logs:
                navTile(tile, isSelected: selection == .logs)
            case .about:
                navTile(tile, isSelected: selection == .about)
            case .connection:
                connectionTile(tile)
            }
        }
        .modifier(EditShakeModifier(isShaking: isEditMode && draggedItem?.id != tile.id))
        .overlay(alignment: .topTrailing) {
            if isEditMode {
                editOverlay(tile)
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
            Task {
                if isConnected { await client.post("disconnect") }
                else { await client.post("resume"); await client.post("connect") }
            }
        } onTap: {
            withAnimation(.easeInOut(duration: 0.15)) { selection = .wireguard }
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
            let ep = guardRunning ? "pause" : "resume"
            Task { await client.post(ep) }
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

    // --- Profile 磁贴（内容随尺寸自适应）---
    private func profileTile(_ tile: TileData) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { selection = .wireguard }
        } label: {
            VStack(alignment: .leading, spacing: tile.size == .small ? 4 : 8) {
                // 第一行：图标 + 名称
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: tileSizeIcon(tile.size) - 4))
                        .foregroundStyle(.orange)
                    Text(client.status?.service ?? "无配置")
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
                                Task { await client.post("resume"); await client.post("connect") }
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
        VStack(spacing: tile.size == .small ? 6 : 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.arrow.down.circle")
                    .font(.system(size: tileSizeIcon(tile.size) - 6))
                    .foregroundStyle(.secondary)
                Text("连接")
                    .font(tile.size == .small ? .subheadline : (tile.size == .medium ? .body : .title3))
                    .fontWeight(.medium)
                Spacer()
                if isConnected { Circle().fill(.green).frame(width: 6, height: 6) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up").font(.system(size: 9))
                        Text("0.00 B/s").font(.caption2.monospacedDigit())
                    }.foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down").font(.system(size: 9))
                        Text("0.00 B/s").font(.caption2.monospacedDigit())
                    }.foregroundStyle(.secondary)
                }
                Spacer()
                Canvas { context, size in
                    let w = size.width; let h = size.height
                    let gradient = Gradient(colors: [.clear, WgTheme.accent.opacity(0.3), .clear])
                    context.fill(Path { path in
                        path.move(to: CGPoint(x: 0, y: h))
                        var x: CGFloat = 0
                        while x < w {
                            let y = h * 0.3 + sin(x * 0.05) * h * 0.2 + CGFloat.random(in: -h*0.05...h*0.05)
                            path.addLine(to: CGPoint(x: x, y: y)); x += 2
                        }
                        path.addLine(to: CGPoint(x: w, y: h)); path.closeSubpath()
                    }, with: .linearGradient(gradient, startPoint: CGPoint(x: 0, y: h*0.5), endPoint: CGPoint(x: w, y: h*0.5)))
                }
                .frame(width: tile.size == .small ? 60 : (tile.size == .medium ? 100 : 140),
                       height: tile.size == .small ? 22 : (tile.size == .medium ? 28 : 40))
                .opacity(isConnected ? 0.8 : 0.3)
            }

            // 中尺寸：简要连接状态
            if tile.size == .medium {
                Divider().opacity(0.15)
                HStack(spacing: 6) {
                    Circle().fill(isConnected ? Color.green : Color.gray.opacity(0.3)).frame(width: 6, height: 6)
                    Text(isConnected ? "已建立隧道" : "未连接")
                        .font(.system(size: 10)).foregroundStyle(isConnected ? .green : .secondary)
                    Spacer()
                }
            }

            // 大尺寸时展示更多信息
            if tile.size == .large {
                Divider().opacity(0.2)
                VStack(alignment: .leading, spacing: 4) {
                    if let s = client.status {
                        connDetailRow("状态", value: s.state == "Connected" ? "已连接" : "未连接", color: s.state == "Connected" ? .green : .red)
                        connDetailRow("Profile", value: s.service.isEmpty ? "无" : s.service)
                        connDetailRow("守护", value: guardRunning ? "运行中" : "暂停")
                    } else {
                        Text("无数据").font(.caption2).foregroundStyle(.tertiary)
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
                                Task { await client.post("resume"); await client.post("connect") }
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
                    // 循环切换：small → medium → large → small
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

    // MARK: - 磁贴网格（空白处长按进编辑模式，磁贴长按/重按呼出菜单）

    private var tileGridContent: some View {
        // 用 LazyVGrid 实现真正的 2 列均分布局（SwiftUI 原生网格）
        let gridItems = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

        return LazyVGrid(columns: gridItems, spacing: 8) {
            ForEach(tiles) { tile in
                switch tile.size {
                case .large:
                    // large 占满两列
                    tileCell(tile)
                        .gridCellColumns(2)
                case .medium:
                    // medium 也占满一行两列
                    tileCell(tile)
                        .gridCellColumns(2)
                case .small:
                    // small 占一列，两个自动并排
                    tileCell(tile)
                }
            }
        }
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
            if !isEditMode {
                VStack(spacing: 4) {
                    // 添加磁贴按钮
                    Button { showAddSheet = true } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus").font(.system(size: 9))
                            Text("添加磁贴")
                                .font(.system(size: 9)).foregroundStyle(WgTheme.accent)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)

                    // 长按进入编辑
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
                }
            } else {
                // 编辑模式下显示添加按钮（高亮）
                HStack(spacing: 6) {
                    Button { showAddSheet = true } label: {
                        Label("添加磁贴", systemImage: "plus.circle.fill")
                            .font(.caption2).foregroundStyle(WgTheme.accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 8)
                                .fill(WgTheme.accent.opacity(0.1)))
                            .overlay(RoundedRectangle(cornerRadius: 8)
                                .stroke(WgTheme.accent.opacity(0.25), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("拖拽排序 · 点击退出")
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
    }

    /// 单个磁贴单元格（LazyVGrid 内渲染，small 自动均分）
    @ViewBuilder
    private func tileCell(_ tile: TileData) -> some View {
        cellBody(tile)
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
            Button {
                resizeTile(tile, to: .small)
            } label: { Label("小 (1 格)", systemImage: "square") }
        }
        if tile.size != .medium {
            Button {
                resizeTile(tile, to: .medium)
            } label: { Label("中 (2 格)", systemImage: "rectangle") }
        }
        if tile.size != .large {
            Button {
                resizeTile(tile, to: .large)
            } label: { Label("大 (4 格)", systemImage: "rectangle.3.groupfill") }
        }

        Divider()

        Button(role: .destructive) {
            withAnimation(.spring(response: 0.3)) {
                tiles.removeAll { $0.id == tile.id }
            }
        } label: { Label("移除磁贴", systemImage: "trash") }
    }

    /// 调整磁贴尺寸
    private func resizeTile(_ tile: TileData, to newSize: TileSize) {
        withAnimation(.spring(response: 0.3)) {
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
    func buildTileRows() -> [[TileData]] {
        let cols = 2
        var grid: [Bool] = Array(repeating: false, count: 100) // 50 行 * 2 列
        var result: [[TileData]] = []

        for tile in tiles {
            let w: Int  // 占用列数
            let h: Int  // 占用行数
            switch tile.size {
            case .small:  w = 1; h = 1
            case .medium: w = 2; h = 1
            case .large:  w = 2; h = 2
            }

            // 找空位（从左到右，从上到下）
            var placed = false
            for startRow in 0..<49 {
                let base = startRow * cols

                // 检查是否所有目标格子都空闲
                var canFit = true
                outer: for r in 0..<h {
                    for c in 0..<w {
                        if base + r * cols + c >= grid.count || grid[base + r * cols + c] {
                            canFit = false
                            break outer
                        }
                    }
                }
                guard canFit else { continue }

                // 标记占用
                for r in 0..<h {
                    for c in 0..<w { grid[base + r * cols + c] = true }
                }

                // 将此磁贴放入对应行的数组中
                for r in 0..<h {
                    while result.count <= startRow + r { result.append([]) }
                    // 只在第一行添加该磁贴（后续行留空或已有其他磁贴）
                    if r == 0 { result[startRow + r].append(tile) }
                }
                placed = true
                break
            }

            if !placed {
                // 放不下就追加到新区域
                while result.last?.count ?? 0 > 0 && result.count % 2 != 0 { /* 对齐 */ }
                let newRowIdx = result.count
                while result.count <= newRowIdx { result.append([]) }
                result[newRowIdx].append(tile)

                // large 需要额外一行
                if tile.size == .large { result.append([]) }

                for r in 0..<h {
                    for c in 0..<w {
                        let idx = (newRowIdx + r) * cols + c
                        if idx < grid.count { grid[idx] = true }
                    }
                }
            }
        }

        return result.isEmpty ? [[]] : result
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
