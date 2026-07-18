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
                .background(WgTheme.cardBg)
                .clipShape(Capsule())
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
            .background(WgTheme.cardBg)
            .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius).stroke(WgTheme.cardBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: WgTheme.cardRadius))
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

struct SettingsView: View {
    @EnvironmentObject var client: DaemonClient
    @AppStorage("appLanguage") private var appLanguageRaw = WgAppLanguage.system.rawValue
    @AppStorage("appAppearance") private var appAppearanceRaw = WgAppAppearance.system.rawValue
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
                settingField("探测目标", placeholder: "https://1.1.1.1", text: $client.healthCheckTarget)
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
            .background(WgTheme.cardBg)
            .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius).stroke(WgTheme.cardBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: WgTheme.cardRadius))
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
