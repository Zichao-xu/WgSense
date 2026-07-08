import SwiftUI

// 占位页：未来模块（传输/代理）
struct PlaceholderView: View {
    let title: String
    let icon: String
    let desc: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title).font(.title).fontWeight(.medium)
            Text(desc).foregroundStyle(.secondary)
            Text("即将推出")
                .font(.caption)
                .padding(6)
                .background(.regularMaterial)
                .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// 日志页（阶段 1 简化：显示 daemon 连接状态）
struct LogsView: View {
    @EnvironmentObject var client: DaemonClient

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("日志").font(.largeTitle).fontWeight(.semibold)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    logLine("WgSense daemon", client.status != nil ? "已连接" : "未连接")
                    if let s = client.status {
                        logLine("当前状态", "\(s.state) · profile=\(s.service)")
                        logLine("位置", s.at_home ? "在家网段" : "在外")
                        logLine("智能管理", s.paused ? "已暂停" : "运行中")
                    }
                    logLine("Profiles", client.profiles.joined(separator: ", "))
                    logLine("提示", "详细日志待 daemon /api/logs 端点（阶段 2）")
                }
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(20)
    }

    private func logLine(_ tag: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(tag).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(value)
            Spacer()
        }
    }
}

// 设置页（阶段 1 简化）
struct SettingsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("设置").font(.largeTitle).fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 8) {
                settingRow("配置目录", "~/.local/share/wgsense/profiles/")
                settingRow("探测目标", "https://www.google.com")
                settingRow("巡检间隔", "10 秒")
                settingRow("假连接检测间隔", "30 秒")
                settingRow("自动拉起宽限期", "20 秒")
            }
            Text("详细设置（家网段/间隔/探测目标等）待阶段 2 配置 UI")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private func settingRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(.body, design: .monospaced))
        }
        .padding(8)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
