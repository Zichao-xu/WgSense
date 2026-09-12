import SwiftUI
import AppKit

// 占位页
struct PlaceholderView: View {
    let title: LocalizedStringKey
    let icon: String
    let desc: LocalizedStringKey

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title).font(.title2).fontWeight(.medium)
            Text(desc).foregroundStyle(.secondary)
            Text("即将推出")
                .font(.caption)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .wgFloatingControlSurface(cornerRadius: 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// 日志页
struct LogsView: View {
    @EnvironmentObject var client: DaemonClient
    @State private var autoScroll = true
    @State private var logLimit = 200
    @State private var isRefreshing = false

    private var visibleLogLines: [DaemonClient.LogLine] {
        Array(client.logLines.suffix(logLimit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WgTheme.spacing) {
            HStack(spacing: 10) {
                Text("日志").font(.title2).fontWeight(.semibold)
                Text(client.status != nil ? "实时" : "daemon 未连接")
                    .font(.caption)
                    .foregroundStyle(client.status != nil ? .green : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((client.status != nil ? Color.green : Color.gray).opacity(0.12), in: Capsule())
                Spacer()
                Toggle("跟随", isOn: $autoScroll)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Picker("数量", selection: $logLimit) {
                    Text("100").tag(100)
                    Text("200").tag(200)
                    Text("500").tag(500)
                }
                .labelsHidden()
                .frame(width: 80)
                Button {
                    Task { await refreshLogs() }
                } label: {
                    Image(systemName: isRefreshing ? "hourglass" : "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRefreshing)
            }

            HStack(spacing: 14) {
                statusChip("daemon", client.status != nil ? "已连接" : "未连接")
                if let s = client.status {
                    statusChip("状态", "\(s.state) / \(s.service)")
                    statusChip("网络", s.isTrustedNetwork ? "受信任" : "非受信任")
                    statusChip("管理", client.isGuardOn ? "运行中" : "已暂停")
                }
            }
            .font(.system(.caption, design: .monospaced))

            logStream
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: logLimit) {
            await refreshLogs()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                await refreshLogs()
            }
        }
    }

    private var logStream: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if visibleLogLines.isEmpty {
                        ContentUnavailableView("暂无日志", systemImage: "scroll")
                            .frame(maxWidth: .infinity, minHeight: 260)
                    } else {
                        ForEach(Array(visibleLogLines.enumerated()), id: \.element.id) { index, line in
                            HStack(alignment: .top, spacing: 10) {
                                Text(String(format: "%04d", index + 1))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 42, alignment: .trailing)
                                Text(line.text)
                                    .textSelection(.enabled)
                                    .foregroundStyle(.primary.opacity(0.86))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(line.id)
                        }
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .padding(14)
            }
            .wgTimelineScroller()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .wgGlassSurface()
            .onChange(of: visibleLogLines.last?.id) {
                guard autoScroll, let last = visibleLogLines.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private func refreshLogs() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        await client.fetchLogs(n: logLimit)
        isRefreshing = false
    }

    private func statusChip(_ tag: LocalizedStringKey, _ value: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Text(tag).foregroundStyle(.secondary)
            Text(value)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.05), in: Capsule())
    }
}

// MARK: - 设置页

private enum WgGlassEditTarget: String, CaseIterable, Identifiable {
    case current
    case dark
    case light

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .current: return "当前模式"
        case .dark: return "深色"
        case .light: return "浅色"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var client: DaemonClient
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appLanguage") private var appLanguageRaw = WgAppLanguage.system.rawValue
    @AppStorage("appAppearance") private var appAppearanceRaw = WgAppAppearance.system.rawValue
    @AppStorage("visualTheme") private var visualThemeRaw = WgVisualTheme.classic.rawValue
    @AppStorage("glassEditTarget") private var glassEditTargetRaw = WgGlassEditTarget.current.rawValue
    @AppStorage("glassDarkPageDepth") private var darkPageDepth = WgGlassDefaults.darkPageDepth
    @AppStorage("glassLightPageDepth") private var lightPageDepth = WgGlassDefaults.lightPageDepth
    @AppStorage("glassDarkSidebarDepth") private var darkSidebarDepth = WgGlassDefaults.darkSidebarDepth
    @AppStorage("glassLightSidebarDepth") private var lightSidebarDepth = WgGlassDefaults.lightSidebarDepth
    @AppStorage("glassDarkTileDepth") private var darkTileDepth = WgGlassDefaults.darkTileDepth
    @AppStorage("glassLightTileDepth") private var lightTileDepth = WgGlassDefaults.lightTileDepth
    @AppStorage("glassDarkContentDepth") private var darkContentDepth = WgGlassDefaults.darkContentDepth
    @AppStorage("glassLightContentDepth") private var lightContentDepth = WgGlassDefaults.lightContentDepth
    @AppStorage("glassDarkFloatingDepth") private var darkFloatingDepth = WgGlassDefaults.darkFloatingDepth
    @AppStorage("glassLightFloatingDepth") private var lightFloatingDepth = WgGlassDefaults.lightFloatingDepth
    @AppStorage("glassDarkPageMaterial") private var darkPageMaterial = WgGlassDefaults.darkPageMaterial
    @AppStorage("glassLightPageMaterial") private var lightPageMaterial = WgGlassDefaults.lightPageMaterial
    @AppStorage("glassDarkSidebarMaterial") private var darkSidebarMaterial = WgGlassDefaults.darkSidebarMaterial
    @AppStorage("glassLightSidebarMaterial") private var lightSidebarMaterial = WgGlassDefaults.lightSidebarMaterial
    @AppStorage("glassDarkTileMaterial") private var darkTileMaterial = WgGlassDefaults.darkTileMaterial
    @AppStorage("glassLightTileMaterial") private var lightTileMaterial = WgGlassDefaults.lightTileMaterial
    @AppStorage("glassDarkContentMaterial") private var darkContentMaterial = WgGlassDefaults.darkContentMaterial
    @AppStorage("glassLightContentMaterial") private var lightContentMaterial = WgGlassDefaults.lightContentMaterial
    @AppStorage("glassDarkFloatingMaterial") private var darkFloatingMaterial = WgGlassDefaults.darkFloatingMaterial
    @AppStorage("glassLightFloatingMaterial") private var lightFloatingMaterial = WgGlassDefaults.lightFloatingMaterial
    @AppStorage("glassDarkTint") private var darkTint = WgGlassDefaults.darkTint
    @AppStorage("glassLightTint") private var lightTint = WgGlassDefaults.lightTint
    @AppStorage("classicDarkPageDepth") private var classicDarkPageDepth = WgClassicDefaults.darkPageDepth
    @AppStorage("classicLightPageDepth") private var classicLightPageDepth = WgClassicDefaults.lightPageDepth
    @AppStorage("classicDarkSidebarDepth") private var classicDarkSidebarDepth = WgClassicDefaults.darkSidebarDepth
    @AppStorage("classicLightSidebarDepth") private var classicLightSidebarDepth = WgClassicDefaults.lightSidebarDepth
    @AppStorage("classicDarkTileDepth") private var classicDarkTileDepth = WgClassicDefaults.darkTileDepth
    @AppStorage("classicLightTileDepth") private var classicLightTileDepth = WgClassicDefaults.lightTileDepth
    @AppStorage("classicDarkContentDepth") private var classicDarkContentDepth = WgClassicDefaults.darkContentDepth
    @AppStorage("classicLightContentDepth") private var classicLightContentDepth = WgClassicDefaults.lightContentDepth
    @AppStorage("classicDarkFloatingDepth") private var classicDarkFloatingDepth = WgClassicDefaults.darkFloatingDepth
    @AppStorage("classicLightFloatingDepth") private var classicLightFloatingDepth = WgClassicDefaults.lightFloatingDepth
    @AppStorage("classicDarkPageMaterial") private var classicDarkPageMaterial = WgClassicDefaults.darkPageMaterial
    @AppStorage("classicLightPageMaterial") private var classicLightPageMaterial = WgClassicDefaults.lightPageMaterial
    @AppStorage("classicDarkSidebarMaterial") private var classicDarkSidebarMaterial = WgClassicDefaults.darkSidebarMaterial
    @AppStorage("classicLightSidebarMaterial") private var classicLightSidebarMaterial = WgClassicDefaults.lightSidebarMaterial
    @AppStorage("classicDarkTileMaterial") private var classicDarkTileMaterial = WgClassicDefaults.darkTileMaterial
    @AppStorage("classicLightTileMaterial") private var classicLightTileMaterial = WgClassicDefaults.lightTileMaterial
    @AppStorage("classicDarkContentMaterial") private var classicDarkContentMaterial = WgClassicDefaults.darkContentMaterial
    @AppStorage("classicLightContentMaterial") private var classicLightContentMaterial = WgClassicDefaults.lightContentMaterial
    @AppStorage("classicDarkFloatingMaterial") private var classicDarkFloatingMaterial = WgClassicDefaults.darkFloatingMaterial
    @AppStorage("classicLightFloatingMaterial") private var classicLightFloatingMaterial = WgClassicDefaults.lightFloatingMaterial
    @AppStorage("classicDarkTint") private var classicDarkTint = WgClassicDefaults.darkTint
    @AppStorage("classicLightTint") private var classicLightTint = WgClassicDefaults.lightTint
    @State private var applyingConfig = false
    @State private var transferToggling = false
    @State private var settingsMessage: String?
    @State private var shuttingDownDaemon = false
    @State private var diagnostics = DaemonDiagnostics()
    @State private var diagnosticsLoading = false
    @State private var maintenanceRunning = false
    @State private var maintenanceMessage: String?
    @State private var pendingMaintenanceAction: MaintenanceAction?
    private let maintenance = DaemonMaintenanceService()

    var body: some View {
        VStack(alignment: .leading, spacing: WgTheme.spacing) {
            Text("设置").font(.title2).fontWeight(.semibold)

            settingsGroup("外观与语言") {
                VStack(spacing: 10) {
                    HStack {
                        Label("界面语言", systemImage: "character.bubble")
                        Spacer()
                        Picker("界面语言", selection: Binding(
                            get: { WgAppLanguage(rawValue: appLanguageRaw) ?? .system },
                            set: { appLanguageRaw = $0.rawValue }
                        )) {
                            ForEach(WgAppLanguage.allCases) { language in
                                Text(language.title).tag(language)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }
                    Divider().opacity(0.3)
                    HStack {
                        Label("主图主题", systemImage: "square.grid.2x2")
                        Spacer()
                        Picker("主图主题", selection: Binding(
                            get: { WgVisualTheme(rawValue: visualThemeRaw) ?? .classic },
                            set: { newValue in
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    visualThemeRaw = newValue.rawValue
                                }
                            }
                        )) {
                            ForEach(WgVisualTheme.allCases) { theme in
                                Text(theme.title).tag(theme)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }
                    Divider().opacity(0.3)
                    HStack {
                        Label("外观模式", systemImage: "circle.lefthalf.filled")
                        Spacer()
                        Picker("外观模式", selection: Binding(
                            get: { WgAppAppearance(rawValue: appAppearanceRaw) ?? .system },
                            set: { newValue in
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    appAppearanceRaw = newValue.rawValue
                                }
                            }
                        )) {
                            ForEach(WgAppAppearance.allCases) { appearance in
                                Text(appearance.title).tag(appearance)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 180)
                    }
                    Divider().opacity(0.3)
                    Text("\(activeVisualThemeTitle) 调校")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                    HStack {
                        Picker("编辑对象", selection: Binding(
                            get: { WgGlassEditTarget(rawValue: glassEditTargetRaw) ?? .current },
                            set: { glassEditTargetRaw = $0.rawValue }
                        )) {
                            ForEach(WgGlassEditTarget.allCases) { target in
                                Text(target.title).tag(target)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Spacer()
                        Text("拖动即生效")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    glassTuningHeader("页面", icon: "macwindow")
                    glassSlider("底板深浅", value: themeBinding(
                        classicDark: $classicDarkPageDepth,
                        classicLight: $classicLightPageDepth,
                        glassDark: $darkPageDepth,
                        glassLight: $lightPageDepth
                    ), range: 0.00...0.95)
                    Divider().opacity(0.3)
                    glassSlider("材质强度", value: themeBinding(
                        classicDark: $classicDarkPageMaterial,
                        classicLight: $classicLightPageMaterial,
                        glassDark: $darkPageMaterial,
                        glassLight: $lightPageMaterial
                    ), range: 0.00...0.75)
                    Divider().opacity(0.3)
                    glassTuningHeader("侧栏", icon: "sidebar.leading")
                    glassSlider("底板深浅", value: themeBinding(classicDark: $classicDarkSidebarDepth, classicLight: $classicLightSidebarDepth, glassDark: $darkSidebarDepth, glassLight: $lightSidebarDepth), range: 0.00...0.95)
                    Divider().opacity(0.3)
                    glassSlider("材质强度", value: themeBinding(classicDark: $classicDarkSidebarMaterial, classicLight: $classicLightSidebarMaterial, glassDark: $darkSidebarMaterial, glassLight: $lightSidebarMaterial), range: 0.00...0.75)
                    Divider().opacity(0.3)
                    glassTuningHeader("磁贴", icon: "square.grid.2x2.fill")
                    glassSlider("底板深浅", value: themeBinding(classicDark: $classicDarkTileDepth, classicLight: $classicLightTileDepth, glassDark: $darkTileDepth, glassLight: $lightTileDepth), range: 0.00...0.95)
                    Divider().opacity(0.3)
                    glassSlider("材质强度", value: themeBinding(classicDark: $classicDarkTileMaterial, classicLight: $classicLightTileMaterial, glassDark: $darkTileMaterial, glassLight: $lightTileMaterial), range: 0.00...0.75)
                    Divider().opacity(0.3)
                    glassTuningHeader("内容", icon: "rectangle.inset.filled")
                    glassSlider("底板深浅", value: themeBinding(classicDark: $classicDarkContentDepth, classicLight: $classicLightContentDepth, glassDark: $darkContentDepth, glassLight: $lightContentDepth), range: 0.00...0.95)
                    Divider().opacity(0.3)
                    glassSlider("材质强度", value: themeBinding(classicDark: $classicDarkContentMaterial, classicLight: $classicLightContentMaterial, glassDark: $darkContentMaterial, glassLight: $lightContentMaterial), range: 0.00...0.75)
                    Divider().opacity(0.3)
                    glassTuningHeader("浮层控件", icon: "slider.horizontal.2.square")
                    glassSlider("底板深浅", value: themeBinding(classicDark: $classicDarkFloatingDepth, classicLight: $classicLightFloatingDepth, glassDark: $darkFloatingDepth, glassLight: $lightFloatingDepth), range: 0.00...0.95)
                    Divider().opacity(0.3)
                    glassSlider("材质强度", value: themeBinding(classicDark: $classicDarkFloatingMaterial, classicLight: $classicLightFloatingMaterial, glassDark: $darkFloatingMaterial, glassLight: $lightFloatingMaterial), range: 0.00...0.75)
                    Divider().opacity(0.3)
                    glassTuningHeader("全局状态", icon: "paintpalette")
                    glassSlider("状态色强度", value: themeBinding(classicDark: $classicDarkTint, classicLight: $classicLightTint, glassDark: $darkTint, glassLight: $lightTint), range: 0.00...0.55)
                    Divider().opacity(0.3)
                    HStack(spacing: 8) {
                        Button {
                            applyGlassDefaults()
                        } label: {
                            Label("恢复默认", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button {
                            applyRecommendedGlass()
                        } label: {
                            Label("推荐值", systemImage: "sparkles")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        Spacer()
                        Text("拖动即生效")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                .padding(.vertical, 6)
            }

            // 后台服务
            settingsGroup("后台服务") {
                daemonControlSection
            }

            // 暂停
            settingsGroup("暂停") {
                settingStepper("暂停时长", value: $client.pauseMinutes, range: 1...120, unit: "分钟")
            }

            // 自动化策略
            settingsGroup("自动化策略") {
                Toggle("非受信任网络自动连接", isOn: $client.autoConnectUntrusted)
                    .padding(.vertical, 6)
                Divider().opacity(0.3)
                settingField("受信任网络前缀", placeholder: "例：10.0.0., 192.168.1.", text: $client.trustedNetworkPrefixes)
                Divider().opacity(0.3)
                settingStepper("巡检间隔", value: $client.intervalSeconds, range: 5...300, step: 5, unit: "秒")
                Divider().opacity(0.3)
                settingStepper("拉起宽限期", value: $client.autoUpGraceSeconds, range: 5...120, step: 5, unit: "秒")
            }

            // 假连接检测
            settingsGroup("假连接检测") {
                settingField("探测目标", placeholder: "https://www.gstatic.com/generate_204", text: $client.healthCheckTarget)
            }

            // 系统
            settingsGroup("系统") {
                settingInfo("配置目录", "~/.local/share/wgsense/profiles/")
                Divider().opacity(0.3)
                settingInfo("daemon API", "127.0.0.1:8765")
                Divider().opacity(0.3)
                settingInfo("日志文件", "/var/log/wgsense-daemon.log")
            }

            // 传输（LocalSend 兼容）
            transferSettingsSection

            // 应用按钮
            Button {
                Task {
                    applyingConfig = true
                    let ok = await client.syncConfig()
                    settingsMessage = ok ? "配置已应用" : "配置应用失败"
                    applyingConfig = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        settingsMessage = nil
                    }
                }
            } label: {
                Label {
                    Text(LocalizedStringKey(applyingConfig ? "正在应用..." : "应用配置到 daemon"))
                } icon: {
                    Image(systemName: applyingConfig ? "hourglass" : "arrow.triangle.2.circlepath")
                }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(applyingConfig)

            if let settingsMessage {
                Text(LocalizedStringKey(settingsMessage))
                    .font(.caption)
                    .foregroundStyle(settingsMessage.contains("失败") ? .orange : .green)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            Task {
                await client.fetchTransferState()
                await refreshDiagnostics()
            }
        }
        .confirmationDialog(
            pendingMaintenanceAction?.title ?? "确认操作",
            isPresented: Binding(
                get: { pendingMaintenanceAction != nil },
                set: { if !$0 { pendingMaintenanceAction = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let action = pendingMaintenanceAction {
                if action.role == "destructive" {
                    Button(action.title, role: .destructive) {
                        runMaintenance(action)
                    }
                } else {
                    Button(action.title) {
                        runMaintenance(action)
                    }
                }
            }
            Button("取消", role: .cancel) { pendingMaintenanceAction = nil }
        } message: {
            Text(pendingMaintenanceAction?.message ?? "")
        }
    }

    // MARK: - 组件

    private var daemonModeText: String {
        guard let status = client.status else { return "离线" }
        if status.app_owned == true {
            return status.passive == true ? "App 临时服务 / 被动" : "App 临时服务 / 网络管理"
        }
        return status.passive == true ? "系统服务 / 被动" : "系统服务 / 网络管理"
    }

    @ViewBuilder
    private var daemonControlSection: some View {
        settingInfo("连接状态", client.status != nil ? "已连接" : "未连接")
        Divider().opacity(0.3)
        settingInfo("运行模式", daemonModeText)
        Divider().opacity(0.3)
        settingInfo("系统 helper", diagnostics.installedSummary)
        Divider().opacity(0.3)
        settingInfo("权限状态", diagnostics.permissionSummary)
        Divider().opacity(0.3)
        settingInfo("残留检查", diagnostics.residualSummary)
        Divider().opacity(0.3)
        if !diagnostics.routeLines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("可疑路由").foregroundStyle(.secondary)
                ForEach(diagnostics.routeLines.prefix(4), id: \.self) { line in
                    Text(line)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.vertical, 6)
            Divider().opacity(0.3)
        }
        HStack(spacing: 8) {
            maintenanceButton("诊断", icon: diagnosticsLoading ? "hourglass" : "stethoscope") {
                Task { await refreshDiagnostics() }
            }
            .disabled(diagnosticsLoading || maintenanceRunning)
            maintenanceButton("导出诊断", icon: "doc.text.magnifyingglass") {
                exportDiagnostics()
            }
            .disabled(maintenanceRunning)
            maintenanceButton("导出日志", icon: "square.and.arrow.down") {
                exportDaemonLog()
            }
            .disabled(maintenanceRunning)
            Spacer()
        }
        .padding(.vertical, 6)
        Divider().opacity(0.3)
        HStack(spacing: 8) {
            maintenanceButton("安装", icon: "arrow.down.app") {
                pendingMaintenanceAction = .installSystemHelper
            }
            maintenanceButton("卸载", icon: "trash", roleColor: .red) {
                pendingMaintenanceAction = .uninstallSystemHelper
            }
            maintenanceButton("重启", icon: "arrow.clockwise") {
                pendingMaintenanceAction = .restartSystemHelper
            }
            maintenanceButton("清理网络", icon: "cross.case", roleColor: .orange) {
                pendingMaintenanceAction = .cleanupNetworkState
            }
            Spacer()
            if maintenanceRunning {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 6)
        .disabled(maintenanceRunning || diagnosticsLoading)
        if let maintenanceMessage {
            Divider().opacity(0.3)
            Text(maintenanceMessage)
                .font(.caption)
                .foregroundStyle(maintenanceMessage.contains("失败") ? .orange : .green)
                .padding(.vertical, 6)
        }
        Divider().opacity(0.3)
        HStack {
            Text("App 临时服务")
            Spacer()
            Button {
                Task {
                    shuttingDownDaemon = true
                    let ok = await client.shutdownAppOwnedDaemon()
                    settingsMessage = ok ? "后台服务已关闭" : "后台服务关闭失败"
                    await refreshDiagnostics()
                    shuttingDownDaemon = false
                }
            } label: {
                Label {
                    Text(LocalizedStringKey(shuttingDownDaemon ? "正在关闭..." : "关闭临时服务"))
                } icon: {
                    Image(systemName: "power")
                }
            }
            .disabled(shuttingDownDaemon || client.status?.app_owned != true)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var transferSettingsSection: some View {
        settingsGroup("文件传输") {
            HStack {
                Text("接收服务").font(.body).foregroundStyle(.primary)
                Spacer()
                HStack(spacing: 8) {
                    Button { Task { await client.fetchTransferState() } } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("刷新接收服务状态")
                    Toggle("", isOn: Binding(
                        get: { client.transferState?.running ?? false },
                        set: { enabled in
                            Task {
                                transferToggling = true
                                let ok = await client.setTransferReceiveEnabled(enabled)
                                if !ok { await client.fetchTransferState() }
                                transferToggling = false
                            }
                        }
                    ))
                    .labelsHidden()
                    .disabled(transferToggling)
                    if transferToggling {
                        ProgressView().scaleEffect(0.6)
                    }
                }
            }
            Divider().opacity(0.3)
            settingInfo("设备别名", client.transferState?.alias ?? "WgSense-Mac")
            Divider().opacity(0.3)
            settingInfo("端口", "\(client.transferState?.port ?? 53317)")
            Divider().opacity(0.3)
            settingInfo("保存目录", client.transferState?.downloads ?? "~/Downloads/WgSense")
        }
    }

    private func settingsGroup<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).fontWeight(.medium).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                content()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .wgSettingsPanelSurface()
        }
    }

    private func settingToggle(_ label: LocalizedStringKey, isOn: Binding<Bool>, isLoading: Binding<Bool>) -> some View {
        HStack {
            Toggle(label, isOn: isOn)
                .disabled(isLoading.wrappedValue)
            if isLoading.wrappedValue {
                ProgressView().scaleEffect(0.7)
            }
        }
        .padding(.vertical, 6)
    }

    private func glassTuningHeader(_ title: LocalizedStringKey, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func glassBinding(dark: Binding<Double>, light: Binding<Double>) -> Binding<Double> {
        Binding {
            glassEditsDarkValues ? dark.wrappedValue : light.wrappedValue
        } set: { newValue in
            if glassEditsDarkValues {
                dark.wrappedValue = newValue
            } else {
                light.wrappedValue = newValue
            }
        }
    }

    private var activeVisualTheme: WgVisualTheme {
        WgVisualTheme(rawValue: visualThemeRaw) ?? .classic
    }

    private var activeVisualThemeTitle: String {
        switch activeVisualTheme {
        case .classic:
            return "经典主题"
        case .liquidGlass:
            return "Liquid Glass"
        }
    }

    private func themeBinding(
        classicDark: Binding<Double>,
        classicLight: Binding<Double>,
        glassDark: Binding<Double>,
        glassLight: Binding<Double>
    ) -> Binding<Double> {
        switch activeVisualTheme {
        case .classic:
            return glassBinding(dark: classicDark, light: classicLight)
        case .liquidGlass:
            return glassBinding(dark: glassDark, light: glassLight)
        }
    }

    private var glassEditsDarkValues: Bool {
        switch WgGlassEditTarget(rawValue: glassEditTargetRaw) ?? .current {
        case .dark:
            return true
        case .light:
            return false
        case .current:
            return colorScheme == .dark
        }
    }

    private func glassSlider(_ label: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .frame(width: 92, alignment: .leading)
            Slider(value: value, in: range)
            Text("\(Int(value.wrappedValue * 100))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
        .padding(.vertical, 7)
    }

    private func applyGlassDefaults() {
        withAnimation(.easeInOut(duration: 0.18)) {
            switch activeVisualTheme {
            case .classic:
                classicDarkPageDepth = WgClassicDefaults.darkPageDepth
                classicLightPageDepth = WgClassicDefaults.lightPageDepth
                classicDarkSidebarDepth = WgClassicDefaults.darkSidebarDepth
                classicLightSidebarDepth = WgClassicDefaults.lightSidebarDepth
                classicDarkTileDepth = WgClassicDefaults.darkTileDepth
                classicLightTileDepth = WgClassicDefaults.lightTileDepth
                classicDarkContentDepth = WgClassicDefaults.darkContentDepth
                classicLightContentDepth = WgClassicDefaults.lightContentDepth
                classicDarkFloatingDepth = WgClassicDefaults.darkFloatingDepth
                classicLightFloatingDepth = WgClassicDefaults.lightFloatingDepth
                classicDarkPageMaterial = WgClassicDefaults.darkPageMaterial
                classicLightPageMaterial = WgClassicDefaults.lightPageMaterial
                classicDarkSidebarMaterial = WgClassicDefaults.darkSidebarMaterial
                classicLightSidebarMaterial = WgClassicDefaults.lightSidebarMaterial
                classicDarkTileMaterial = WgClassicDefaults.darkTileMaterial
                classicLightTileMaterial = WgClassicDefaults.lightTileMaterial
                classicDarkContentMaterial = WgClassicDefaults.darkContentMaterial
                classicLightContentMaterial = WgClassicDefaults.lightContentMaterial
                classicDarkFloatingMaterial = WgClassicDefaults.darkFloatingMaterial
                classicLightFloatingMaterial = WgClassicDefaults.lightFloatingMaterial
                classicDarkTint = WgClassicDefaults.darkTint
                classicLightTint = WgClassicDefaults.lightTint
            case .liquidGlass:
                darkPageDepth = WgGlassDefaults.darkPageDepth
                lightPageDepth = WgGlassDefaults.lightPageDepth
                darkSidebarDepth = WgGlassDefaults.darkSidebarDepth
                lightSidebarDepth = WgGlassDefaults.lightSidebarDepth
                darkTileDepth = WgGlassDefaults.darkTileDepth
                lightTileDepth = WgGlassDefaults.lightTileDepth
                darkContentDepth = WgGlassDefaults.darkContentDepth
                lightContentDepth = WgGlassDefaults.lightContentDepth
                darkFloatingDepth = WgGlassDefaults.darkFloatingDepth
                lightFloatingDepth = WgGlassDefaults.lightFloatingDepth
                darkPageMaterial = WgGlassDefaults.darkPageMaterial
                lightPageMaterial = WgGlassDefaults.lightPageMaterial
                darkSidebarMaterial = WgGlassDefaults.darkSidebarMaterial
                lightSidebarMaterial = WgGlassDefaults.lightSidebarMaterial
                darkTileMaterial = WgGlassDefaults.darkTileMaterial
                lightTileMaterial = WgGlassDefaults.lightTileMaterial
                darkContentMaterial = WgGlassDefaults.darkContentMaterial
                lightContentMaterial = WgGlassDefaults.lightContentMaterial
                darkFloatingMaterial = WgGlassDefaults.darkFloatingMaterial
                lightFloatingMaterial = WgGlassDefaults.lightFloatingMaterial
                darkTint = WgGlassDefaults.darkTint
                lightTint = WgGlassDefaults.lightTint
            }
        }
    }

    private func applyRecommendedGlass() {
        applyGlassDefaults()
    }

    private func maintenanceButton(
        _ title: LocalizedStringKey,
        icon: String,
        roleColor: Color = .secondary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .labelStyle(.titleAndIcon)
                .foregroundStyle(roleColor)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func settingStepper(_ label: LocalizedStringKey, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1, unit: LocalizedStringKey) -> some View {
        HStack {
            Text(label)
            Spacer()
            Stepper(value: value, in: range, step: step) {
                HStack(spacing: 4) {
                    Text("\(value.wrappedValue)")
                    Text(unit)
                }
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func settingField(_ label: LocalizedStringKey, placeholder: LocalizedStringKey, text: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
        }
        .padding(.vertical, 6)
    }

    private func settingInfo(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(LocalizedStringKey(value))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    // MARK: - 后台服务维护

    private func refreshDiagnostics() async {
        diagnosticsLoading = true
        diagnostics = await maintenance.diagnostics()
        diagnosticsLoading = false
    }

    private func runMaintenance(_ action: MaintenanceAction) {
        pendingMaintenanceAction = nil
        Task {
            maintenanceRunning = true
            let result = await maintenance.perform(action)
            maintenanceMessage = result.succeeded ? "\(action.title)完成" : "\(action.title)失败：\(result.output)"
            await client.fetchStatus()
            await refreshDiagnostics()
            maintenanceRunning = false
        }
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "wgsense-diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try maintenance.exportDiagnostics(diagnostics, to: url)
            maintenanceMessage = "诊断已导出"
        } catch {
            maintenanceMessage = "诊断导出失败：\(error.localizedDescription)"
        }
    }

    private func exportDaemonLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "wgsense-daemon.log"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            maintenanceRunning = true
            let result = await maintenance.exportDaemonLog(to: url)
            maintenanceMessage = result.succeeded ? "日志已导出" : "日志导出失败：\(result.output)"
            maintenanceRunning = false
        }
    }
}
