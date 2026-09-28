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
                .wgFloatingControlSurface(cornerRadius: 3)
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
        WgPage(title: "日志", subtitle: client.status != nil ? "后台服务实时输出" : "后台服务未运行", word: "LOGS") {
            HStack(spacing: 10) {
                Toggle("跟随", isOn: $autoScroll)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Picker("数量", selection: $logLimit) {
                    Text("100 行").tag(100)
                    Text("200 行").tag(200)
                    Text("500 行").tag(500)
                }
                .labelsHidden()
                .fixedSize()
                Button { Task { await refreshLogs() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(WgToolbarIconButtonStyle())
                    .disabled(isRefreshing)
                    .help("刷新")
            }
        } content: {
            if let s = client.status {
                HStack(spacing: 8) {
                    statusChip("网络", s.isTrustedNetwork ? "在家" : "外部网络", tint: s.isTrustedNetwork ? .teal : .blue)
                    statusChip("隧道", client.isTunnelUp ? "已连接" : "未连接", tint: client.isTunnelUp ? .green : .gray)
                    statusChip("守护", client.isGuardOn ? "运行中" : "已关闭", tint: client.isGuardOn ? .blue : .gray)
                    statusChip("配置", LocalizedStringKey(s.service), tint: .orange)
                }
            }
            logStream
        }
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
                LazyVStack(alignment: .leading, spacing: 5) {
                    if visibleLogLines.isEmpty {
                        ContentUnavailableView("暂无日志", systemImage: "text.alignleft")
                            .frame(maxWidth: .infinity, minHeight: 260)
                    } else {
                        ForEach(Array(visibleLogLines.enumerated()), id: \.element.id) { index, line in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Circle()
                                    .fill(Self.levelColor(line.text))
                                    .frame(width: 5, height: 5)
                                    .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                                Text(verbatim: line.text)
                                    .textSelection(.enabled)
                                    .foregroundStyle(.primary.opacity(0.86))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .id(line.id)
                        }
                    }
                }
                .font(.system(size: 12, design: .monospaced))
                .padding(16)
            }
            .frame(maxWidth: .infinity, minHeight: 460)
            .wgInteractiveSurface(cornerRadius: WgDesign.cardRadius)
            .onChange(of: visibleLogLines.last?.id) {
                guard autoScroll, let last = visibleLogLines.last else { return }
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    /// 行首圆点按内容粗分级别：失败/错误红、警告橙、成功绿，其余中性。
    private static func levelColor(_ text: String) -> Color {
        let lower = text.lowercased()
        if lower.contains("失败") || lower.contains("错误") || lower.contains("error") || lower.contains("fatal") { return .red }
        if lower.contains("warn") || lower.contains("退避") || lower.contains("重试") { return .orange }
        if text.contains("✅") || text.contains("成功") || text.contains("已连接") { return .green }
        return .secondary.opacity(0.5)
    }

    private func refreshLogs() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        await client.fetchLogs(n: logLimit)
        isRefreshing = false
    }

    private func statusChip(_ tag: LocalizedStringKey, _ value: LocalizedStringKey, tint: Color) -> some View {
        HStack(spacing: 6) {
            WgStatusDot(color: tint, isOn: tint != .gray)
            Text(tag).foregroundStyle(.secondary)
            Text(value).fontWeight(.medium)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .wgInteractiveSurface(cornerRadius: 3)
    }
}

// MARK: - 设置页


struct SettingsView: View {
    @EnvironmentObject var client: DaemonClient
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appLanguage") private var appLanguageRaw = WgAppLanguage.system.rawValue
    @AppStorage("appAppearance") private var appAppearanceRaw = WgAppAppearance.system.rawValue
    @AppStorage("backdropMode") private var backdropModeRaw = WgBackdropMode.liquidRegular.rawValue
    @AppStorage("glassTintStrength") private var glassTintStrength = 0.55
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
        WgPage(title: "设置", word: "SETTINGS") {
            VStack(alignment: .leading, spacing: 22) {
                generalSection
                appearanceSection
                policySection
                transferSettingsSection
                serviceSection
                pathsSection
            }
        }
        .onAppear {
            // 系统会把首个文本框设为焦点并滚动过去；打开设置时不应落在可编辑字段上。
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
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

    // MARK: - 分组

    private var generalSection: some View {
        WgSection(title: "通用") {
            WgRow(symbol: "character.bubble.fill", tint: .blue, title: "界面语言") {
                Picker("界面语言", selection: Binding(
                    get: { WgAppLanguage(rawValue: appLanguageRaw) ?? .system },
                    set: { appLanguageRaw = $0.rawValue }
                )) {
                    ForEach(WgAppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            WgRowDivider()
            WgRow(symbol: "circle.lefthalf.filled", tint: .indigo, title: "外观模式") {
                Picker("外观模式", selection: Binding(
                    get: { WgAppAppearance(rawValue: appAppearanceRaw) ?? .system },
                    set: { newValue in
                        withAnimation(.easeInOut(duration: 0.3)) { appAppearanceRaw = newValue.rawValue }
                    }
                )) {
                    ForEach(WgAppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private var appearanceSection: some View {
        WgSection(title: "窗口材质", footer: "背景浓度决定壁纸透出多少。") {
            WgRow(symbol: "square.stack.3d.up.fill", tint: .teal, title: "背景模式") {
                Picker("背景模式", selection: Binding(
                    get: { WgBackdropMode(rawValue: backdropModeRaw) ?? .liquidRegular },
                    set: { newValue in
                        withAnimation(.easeInOut(duration: 0.25)) { backdropModeRaw = newValue.rawValue }
                    }
                )) {
                    ForEach(WgBackdropMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            WgRowDivider()
            sliderRow("背景浓度", symbol: "circle.righthalf.filled", tint: .cyan, value: $glassTintStrength, range: 0.0...0.85)
        }
    }

    private var policySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            WgSection(title: "守护与网络") {
                WgRow(symbol: "shield.fill", tint: .blue, title: "非受信任网络自动连接",
                      subtitle: Text("离开受信任网络时自动连上 VPN")) {
                    Toggle("", isOn: $client.autoConnectUntrusted)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(.small)
                }
                WgRowDivider()
                WgRow(symbol: "house.fill", tint: .teal, title: "受信任网络前缀",
                      subtitle: Text("命中这些前缀视为在家，守护会保持 VPN 断开")) {
                    TextField("例：10.0.0., 192.168.1.", text: $client.trustedNetworkPrefixes)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
                WgRowDivider()
                stepperRow("巡检间隔", symbol: "timer", tint: .orange, value: $client.intervalSeconds, range: 5...300, step: 5, unit: "秒")
                WgRowDivider()
                stepperRow("拉起宽限期", symbol: "hourglass", tint: .orange, value: $client.autoUpGraceSeconds, range: 5...120, step: 5, unit: "秒")
                WgRowDivider()
                stepperRow("暂停时长", symbol: "pause.fill", tint: .yellow, value: $client.pauseMinutes, range: 1...120, step: 1, unit: "分钟")
                WgRowDivider()
                WgRow(symbol: "waveform.path.ecg", tint: .green, title: "假连接探测目标",
                      subtitle: Text("隧道显示已连接但探测失败时自动重建")) {
                    TextField("https://www.gstatic.com/generate_204", text: $client.healthCheckTarget)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                }
            }
            HStack(spacing: 10) {
                if let settingsMessage {
                    Label(LocalizedStringKey(settingsMessage),
                          systemImage: settingsMessage.contains("失败") ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(settingsMessage.contains("失败") ? .orange : .green)
                        .transition(.opacity)
                }
                Spacer()
                Button {
                    Task {
                        applyingConfig = true
                        let ok = await client.syncConfig()
                        withAnimation { settingsMessage = ok ? "已应用到后台服务" : "应用失败" }
                        applyingConfig = false
                        try? await Task.sleep(for: .seconds(3))
                        withAnimation { settingsMessage = nil }
                    }
                } label: {
                    Text(LocalizedStringKey(applyingConfig ? "正在应用…" : "应用"))
                }
                .buttonStyle(WgCapsuleButtonStyle(tint: WgInk.signal))
                .disabled(applyingConfig)
            }
            .padding(.horizontal, 4)
        }
    }

    @ViewBuilder
    private var transferSettingsSection: some View {
        WgSection(title: "文件传输") {
            WgRow(symbol: "arrow.down", tint: .blue, title: "接收服务",
                  subtitle: Text("兼容 LocalSend，隧道内设备可直接发送")) {
                HStack(spacing: 8) {
                    if transferToggling { ProgressView().controlSize(.small) }
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
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
                    .disabled(transferToggling)
                }
            }
            WgRowDivider()
            WgRow(symbol: "desktopcomputer", tint: .gray, title: "设备别名") {
                WgValue(client.transferState?.alias ?? "WgSense-Mac")
            }
            WgRowDivider()
            WgRow(symbol: "number", tint: .gray, title: "端口") {
                WgValue("\(client.transferState?.port ?? 53317)", monospaced: true)
            }
            WgRowDivider()
            WgRow(symbol: "folder.fill", tint: .blue, title: "保存目录") {
                WgValue(client.transferState?.downloads ?? "~/Downloads/WgSense")
            }
        }
    }

    private var serviceSection: some View {
        WgSection(title: "后台服务") {
            WgRow(symbol: "server.rack", tint: client.status != nil ? .green : .gray, title: "运行状态") {
                HStack(spacing: 6) {
                    WgStatusDot(color: .green, isOn: client.status != nil)
                    WgValue(daemonModeText)
                }
            }
            WgRowDivider()
            WgRow(symbol: "gearshape.2.fill", tint: .gray, title: "系统服务") {
                WgValue(diagnostics.installedSummary)
            }
            WgRowDivider()
            WgRow(symbol: "lock.fill", tint: .gray, title: "权限") {
                WgValue(diagnostics.permissionSummary)
            }
            WgRowDivider()
            WgRow(symbol: diagnostics.hasResidue ? "exclamationmark.triangle.fill" : "checkmark.seal.fill",
                  tint: diagnostics.hasResidue ? .orange : .green, title: "残留检查") {
                WgValue(diagnostics.residualSummary)
            }
            if diagnostics.hasResidue && !diagnostics.routeLines.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(diagnostics.routeLines.prefix(4), id: \.self) { line in
                        Text(verbatim: line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 50)
                .padding(.trailing, 14)
                .padding(.bottom, 10)
            }
            WgRowDivider(inset: 14)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    maintenanceButton("诊断", icon: "stethoscope") { Task { await refreshDiagnostics() } }
                        .disabled(diagnosticsLoading || maintenanceRunning)
                    maintenanceButton("导出诊断", icon: "doc.text.magnifyingglass") { exportDiagnostics() }
                        .disabled(maintenanceRunning)
                    maintenanceButton("导出日志", icon: "square.and.arrow.down") { exportDaemonLog() }
                        .disabled(maintenanceRunning)
                    Spacer()
                    if maintenanceRunning || diagnosticsLoading { ProgressView().controlSize(.small) }
                }
                HStack(spacing: 8) {
                    maintenanceButton("重新安装", icon: "arrow.down.app") { pendingMaintenanceAction = .installSystemHelper }
                    maintenanceButton("重启服务", icon: "arrow.clockwise") { pendingMaintenanceAction = .restartSystemHelper }
                    maintenanceButton("清理网络", icon: "cross.case", roleColor: .orange) { pendingMaintenanceAction = .cleanupNetworkState }
                    Spacer()
                    maintenanceButton("卸载", icon: "trash", roleColor: .red) { pendingMaintenanceAction = .uninstallSystemHelper }
                }
                .disabled(maintenanceRunning || diagnosticsLoading)
                if let maintenanceMessage {
                    Text(verbatim: maintenanceMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(maintenanceMessage.contains("失败") ? .orange : .green)
                }
                if client.status?.app_owned == true {
                    HStack {
                        Text("旧版临时服务仍在运行").font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        maintenanceButton(shuttingDownDaemon ? "正在关闭…" : "关闭临时服务", icon: "power") {
                            Task {
                                shuttingDownDaemon = true
                                let ok = await client.shutdownAppOwnedDaemon()
                                settingsMessage = ok ? "后台服务已关闭" : "后台服务关闭失败"
                                await refreshDiagnostics()
                                shuttingDownDaemon = false
                            }
                        }
                        .disabled(shuttingDownDaemon)
                    }
                }
            }
            .padding(14)
        }
    }

    private var pathsSection: some View {
        WgSection(title: "路径") {
            WgRow(symbol: "doc.text.fill", tint: .orange, title: "配置目录") { WgValue("~/.local/share/wgsense/profiles/", monospaced: true) }
            WgRowDivider()
            WgRow(symbol: "network", tint: .gray, title: "后台服务接口") { WgValue("127.0.0.1:8765", monospaced: true) }
            WgRowDivider()
            WgRow(symbol: "text.alignleft", tint: .gray, title: "日志文件") { WgValue("/var/log/wgsense-daemon.log", monospaced: true) }
        }
    }

    // MARK: - 组件

    private var daemonModeText: String {
        guard let status = client.status else { return "未运行" }
        if status.app_owned == true {
            return status.passive == true ? "临时服务 · 被动" : "临时服务"
        }
        return status.passive == true ? "系统服务 · 被动" : "系统服务 · 运行中"
    }

    private func sliderRow(_ title: LocalizedStringKey, symbol: String, tint: Color, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        WgRow(symbol: symbol, tint: tint, title: title) {
            HStack(spacing: 10) {
                Slider(value: value, in: range)
                    .controlSize(.small)
                    .frame(width: 160)
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, alignment: .trailing)
            }
        }
    }

    private func stepperRow(_ title: LocalizedStringKey, symbol: String, tint: Color, value: Binding<Int>, range: ClosedRange<Int>, step: Int, unit: LocalizedStringKey) -> some View {
        WgRow(symbol: symbol, tint: tint, title: title) {
            Stepper(value: value, in: range, step: step) {
                HStack(spacing: 3) {
                    Text("\(value.wrappedValue)")
                    Text(unit)
                }
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            .controlSize(.small)
        }
    }

    private func maintenanceButton(
        _ title: LocalizedStringKey,
        icon: String,
        roleColor: Color = .primary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(WgPillButtonStyle(tint: roleColor))
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
