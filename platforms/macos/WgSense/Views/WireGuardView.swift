import SwiftUI

// WireGuard 详情页：Clash Party 风格 — 标题 + Profile 管理表单
struct WireGuardDetailView: View {
    @EnvironmentObject var client: DaemonClient

    var body: some View {
        VStack(alignment: .leading, spacing: WgTheme.spacing) {
            // 页面标题栏
            HStack(spacing: WgSpace.s) {
                Text("WireGuard")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Image(systemName: "pin")
                    .font(.system(size: WgType.sub))
                    .foregroundStyle(.secondary)
            }

            // 连接状态快速概览
            connectionStatusRow

            // Profile 列表
            profileListSection

            Spacer()
        }
    }

    // MARK: - 连接状态行

    private var connectionStatusRow: some View {
        HStack(spacing: WgSpace.l) {
            HStack(spacing: WgSpace.s) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(client.status?.state ?? "Unknown")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            if let s = client.status {
                Text("·")
                    .foregroundStyle(.secondary)
                Text("\(s.service)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(s.paused ? "· 已暂停" : "")
                    .font(.caption)
                    .foregroundStyle(s.paused ? .orange : .clear)
            }

            Spacer()

            if client.isVPNOn {
                Button(client.isAuthorizingDaemon ? "正在授权..." : "断开") {
                    Task { await client.post("disconnect") }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(client.isAuthorizingDaemon)
            } else {
                Button(client.isAuthorizingDaemon ? "正在授权..." : "连接") {
                    Task { await client.post("connect") }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(client.isAuthorizingDaemon || client.isGuardBlockingVPN)
                .help(client.isGuardBlockingVPN ? "在家由守护保持断开；关闭守护后可手动连接" : "")
            }
        }
        .wgPadding(WgSpace.l)
        .wgGlassSurface(tint: statusColor, interactive: true)
    }

    // MARK: - Profile 列表区域

    private var profileListSection: some View {
        VStack(alignment: .leading, spacing: WgTheme.spacing) {
            HStack(spacing: WgSpace.m) {
                Text("配置文件")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)

                Spacer()

                Button { showImport = true } label: {
                    Label("导入", systemImage: "square.and.arrow.down")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button { showWizard = true } label: {
                    Label("手动填写", systemImage: "plus.circle")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if client.profiles.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(client.profiles, id: \.self) { p in
                        profileDetailRow(p)
                        if p != client.profiles.last {
                            Divider().opacity(0.2).wgPadding(.leading, 56)
                        }
                    }
                }
                .wgGlassSurface()
            }
        }
    }

    // MARK: - 状态变量

    @State private var showImport = false
    @State private var showWizard = false
    @State private var editProfile: PName?
    @State private var exportProfile: String?
    @State private var showExport = false
    @State private var showDeleteConfirm = false
    @State private var deleteProfileName: String?

    struct PName: Identifiable {
        let name: String
        var id: String { name }
    }

    // MARK: - Profile 详情行

    private func profileDetailRow(_ name: String) -> some View {
        let isActive = client.status?.service == name
        return HStack(spacing: WgSpace.m) {
            Image(systemName: isActive ? "checkmark.shield.fill" : "shield")
                .font(.system(size: WgType.title))
                .foregroundStyle(isActive ? .green : .secondary.opacity(0.5))

            VStack(alignment: .leading, spacing: WgSpace.xs) {
                Text(name)
                    .font(.subheadline)
                    .fontWeight(isActive ? .semibold : .regular)
                    .foregroundStyle(isActive ? .primary : .secondary)

                if isActive {
                    Text("使用中")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }

            Spacer()

            HStack(spacing: WgSpace.s) {
                if !isActive {
                    Button("切换") {
                        Task { await client.switchProfile(name) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }

                Button { editProfile = PName(name: name) } label: {
                    Image(systemName: "pencil").font(.system(size: WgType.caption))
                }.buttonStyle(.plain).help("编辑")

                Button {
                    exportProfile = name
                    showExport = true
                } label: {
                    Image(systemName: "square.and.arrow.up").font(.system(size: WgType.caption))
                }.buttonStyle(.plain).help("导出")

                Button {
                    deleteProfileName = name
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash").font(.system(size: WgType.caption))
                        .foregroundStyle(.red.opacity(0.6))
                }.buttonStyle(.plain).help("删除")
            }
        }
        .wgPadding(.horizontal, WgSpace.l)
        .wgPadding(.vertical, WgSpace.m)
        .contentShape(Rectangle())
        .confirmationDialog("确认删除「\(name)」？", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) {
                if let name = deleteProfileName {
                    Task {
                        await client.deleteProfile(name: name)
                        await client.fetchProfiles()
                    }
                }
            }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showImport) {
            ImportConfView { name, content in
                Task {
                    await client.importProfile(name: name, content: content)
                    await client.fetchProfiles()
                    showImport = false
                }
            }
        }
        .sheet(isPresented: $showWizard) {
            ManualWizardView { profile in
                Task {
                    await client.saveProfile(profile)
                    await client.fetchProfiles()
                    showWizard = false
                }
            }
        }
        .sheet(item: $editProfile) { item in
            EditProfileView(profileName: item.name) {
                Task {
                    await client.fetchProfiles()
                    if client.status?.service == item.name {
                        await client.post("disconnect")
                        await client.post("connect")
                    }
                }
                editProfile = nil
            }
            .environmentObject(client)
        }
        .sheet(isPresented: $showExport) {
            if let name = exportProfile {
                ExportConfView(profileName: name) { _ in showExport = false }
                    .environmentObject(client)
            }
        }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: WgSpace.l) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: WgType.page))
                .foregroundStyle(.secondary.opacity(0.5))
            Text("还没有 Profile")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("导入 .conf 或手动填写创建")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .wgPadding(.vertical, WgSpace.xxxl)
        .wgGlassSurface()
    }

    // MARK: -

    private var statusColor: Color {
        switch client.status?.state {
        case "Connected": return .green
        case "Disconnected": return .gray
        default: return .orange
        }
    }
}
