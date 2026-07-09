import SwiftUI

// 占位页
struct PlaceholderView: View {
    let title: String
    let icon: String
    let desc: String

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

    var body: some View {
        VStack(alignment: .leading, spacing: WgTheme.spacing) {
            Text("日志").font(.title2).fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 4) {
                logLine("daemon", client.status != nil ? "已连接" : "未连接")
                if let s = client.status {
                    logLine("状态", "\(s.state) · profile=\(s.service)")
                    logLine("位置", s.at_home ? "在家网段" : "在外")
                    logLine("管理", s.paused ? "已暂停" : "运行中")
                }
                logLine("profiles", client.profiles.joined(separator: ", "))
            }
            .font(.system(.caption, design: .monospaced))
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WgTheme.cardBg)
            .overlay(RoundedRectangle(cornerRadius: WgTheme.cardRadius).stroke(WgTheme.cardBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: WgTheme.cardRadius))

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func logLine(_ tag: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(tag).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            Text(value)
            Spacer()
        }
    }
}

// MARK: - 设置页

struct SettingsView: View {
    @EnvironmentObject var client: DaemonClient
    @State private var autoStart = false
    @State private var autoStartLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: WgTheme.spacing) {
            Text("设置").font(.title2).fontWeight(.semibold)

            // 启动
            settingsGroup("启动") {
                settingToggle("开机自动启动", isOn: $autoStart, isLoading: $autoStartLoading)
            }

            // 暂停
            settingsGroup("暂停") {
                settingStepper("暂停时长", value: $client.pauseMinutes, range: 1...120, unit: "分钟")
            }

            // 守护
            settingsGroup("守护") {
                settingField("家网段", placeholder: "10.10.1.", text: $client.homeNetworkPrefixes)
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

            // 应用按钮
            Button {
                Task { await client.syncConfig() }
            } label: {
                Label("应用配置到 daemon", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { checkAutoStartStatus() }
        .onChange(of: autoStart) { newValue in
            if !autoStartLoading { toggleAutoStart(newValue) }
        }
    }

    // MARK: - 组件

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
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

    private func settingToggle(_ label: String, isOn: Binding<Bool>, isLoading: Binding<Bool>) -> some View {
        HStack {
            Toggle(label, isOn: isOn)
                .disabled(isLoading.wrappedValue)
            if isLoading.wrappedValue {
                ProgressView().scaleEffect(0.7)
            }
        }
        .padding(.vertical, 6)
    }

    private func settingStepper(_ label: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1, unit: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Stepper(value: value, in: range, step: step) {
                Text("\(value.wrappedValue) \(unit)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func settingField(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack {
            Text(label)
            Spacer()
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
        }
        .padding(.vertical, 6)
    }

    private func settingInfo(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    // MARK: - 开机启动

    private func checkAutoStartStatus() {
        autoStartLoading = true
        DispatchQueue.global().async {
            let task = Process()
            task.launchPath = "/bin/sh"
            task.arguments = ["-c", "launchctl list 2>/dev/null | grep com.wgsense.daemon"]
            let pipe = Pipe()
            task.standardOutput = pipe
            try? task.run()
            task.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                autoStart = !output.isEmpty
                autoStartLoading = false
            }
        }
    }

    private func toggleAutoStart(_ enable: Bool) {
        autoStartLoading = true
        let action = enable ? "load" : "unload"
        let plist = "/Library/LaunchDaemons/com.wgsense.daemon.plist"

        DispatchQueue.global().async {
            let script = "do shell script \"launchctl \(action) -w \(plist)\" with administrator privileges"
            let task = Process()
            task.launchPath = "/usr/bin/osascript"
            task.arguments = ["-e", script]
            let errPipe = Pipe()
            task.standardError = errPipe
            task.standardOutput = Pipe()
            try? task.run()
            task.waitUntilExit()

            DispatchQueue.main.async {
                if task.terminationStatus != 0 {
                    autoStart = !enable
                }
                autoStartLoading = false
            }
        }
    }
}
