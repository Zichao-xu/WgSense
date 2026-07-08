import SwiftUI
import UniformTypeIdentifiers

// MARK: - Profile 管理入口

struct ProfileManagerView: View {
    @EnvironmentObject var client: DaemonClient
    @State private var showImport = false
    @State private var showWizard = false
    @State private var showExport = false
    @State private var exportProfile: String?
    @State private var showDeleteConfirm = false
    @State private var deleteProfile: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 标题 + 操作按钮
            HStack {
                Text("Profiles").font(.headline)
                Spacer()
                Button {
                    showImport = true
                } label: {
                    Label("导入 .conf", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)

                Button {
                    showWizard = true
                } label: {
                    Label("手动填写", systemImage: "plus.circle")
                }
                .buttonStyle(.borderedProminent)
            }

            // Profile 列表
            if client.profiles.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(client.profiles, id: \.self) { p in
                            profileRow(p)
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showImport) {
            ImportConfView { name, content in
                Task {
                    await client.importProfile(name: name, content: content)
                    await client.fetchProfiles()
                }
                showImport = false
            }
        }
        .sheet(isPresented: $showWizard) {
            ManualWizardView { profile in
                Task {
                    await client.saveProfile(profile)
                    await client.fetchProfiles()
                }
                showWizard = false
            }
        }
        .sheet(isPresented: $showExport) {
            if let name = exportProfile {
                ExportConfView(profileName: name) { success in
                    showExport = false
                }
                .environmentObject(client)
            }
        }
        .confirmationDialog("确认删除？", isPresented: $showDeleteConfirm) {
            Button("删除 \(deleteProfile ?? "")", role: .destructive) {
                if let name = deleteProfile {
                    Task {
                        await client.deleteProfile(name: name)
                        await client.fetchProfiles()
                    }
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("还没有 Profile")
                .font(.headline)
            Text("导入 .conf 文件或手动填写密钥信息")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(30)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func profileRow(_ name: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: client.status?.service == name ? "checkmark.shield.fill" : "shield")
                .foregroundStyle(client.status?.service == name ? .green : .secondary)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.medium)
                if client.status?.service == name {
                    Text("当前使用").font(.caption).foregroundStyle(.green)
                }
            }

            Spacer()

            // 导出
            Button {
                exportProfile = name
                showExport = true
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
            .help("导出 .conf")

            // 删除
            Button {
                deleteProfile = name
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("删除")
        }
        .padding(12)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .transition(.asymmetric(
            insertion: .scale(scale: 0.9).combined(with: .opacity),
            removal: .opacity
        ))
    }
}

// MARK: - 导入 .conf 文件

struct ImportConfView: View {
    @State private var fileName: String = ""
    @State private var fileContent: String = ""
    @State private var profileName: String = ""
    @State private var isDropTargeted = false
    @State private var error: String?
    let onComplete: (String, String) -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("导入 WireGuard 配置").font(.title2).fontWeight(.semibold)

            // 拖拽区域
            VStack(spacing: 8) {
                if fileContent.isEmpty {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.tint)
                        .scaleEffect(isDropTargeted ? 1.15 : 1.0)
                        .animation(.spring(response: 0.3), value: isDropTargeted)

                    Text("拖拽 .conf 文件到此处")
                        .font(.headline)
                    Text("或点击下方按钮选择文件")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("选择文件") { pickFile() }
                        .buttonStyle(.borderedProminent)
                } else {
                    // 已加载预览
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))

                    Text(fileName).font(.headline)
                    ScrollView {
                        Text(fileContent)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 150)
                    .padding(8)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    Button("重新选择") {
                        fileContent = ""
                        fileName = ""
                        profileName = ""
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(30)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isDropTargeted ? Color.accentColor.opacity(0.1) : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(
                                isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                                style: StrokeStyle(lineWidth: 2, dash: [8])
                            )
                    )
            )
            .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
                return true
            }

            // Profile 名称
            if !fileContent.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Profile 名称").font(.caption).foregroundStyle(.secondary)
                    TextField("如：home-vpn", text: $profileName)
                        .textFieldStyle(.roundedBorder)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let error = error {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            // 底部按钮
            HStack {
                Button("取消") { /* 由 sheet 关闭 */ }
                    .buttonStyle(.bordered)
                Spacer()
                Button("导入") {
                    let name = profileName.isEmpty ? fileName.replacingOccurrences(of: ".conf", with: "") : profileName
                    onComplete(name, fileContent)
                }
                .buttonStyle(.borderedProminent)
                .disabled(fileContent.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480, height: 560)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: fileContent.isEmpty)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            loadFile(url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    DispatchQueue.main.async { loadFile(url) }
                }
            }
        }
    }

    private func loadFile(_ url: URL) {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            fileContent = content
            fileName = url.lastPathComponent
            profileName = url.deletingPathExtension().lastPathComponent
            error = nil
        } catch {
            self.error = "读取文件失败: \(error.localizedDescription)"
        }
    }
}

// MARK: - 导出 .conf 文件

struct ExportConfView: View {
    @EnvironmentObject var client: DaemonClient
    let profileName: String
    @State private var content: String = ""
    @State private var loaded = false
    @State private var done = false
    let onComplete: (Bool) -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("导出 \(profileName)").font(.title2).fontWeight(.semibold)

            if !loaded {
                ProgressView("加载配置...")
            } else {
                Image(systemName: done ? "checkmark.circle.fill" : "doc.text.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(done ? Color.green : Color.accentColor)
                    .transition(.scale.combined(with: .opacity))

                Text(done ? "已保存到文件" : "配置内容预览").font(.headline)

                if !done {
                    ScrollView {
                        Text(content)
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 200)
                    .padding(8)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    Button("保存到文件") { saveFile() }
                        .buttonStyle(.borderedProminent)
                }
            }

            Spacer()
            Button(done ? "完成" : "关闭") { onComplete(done) }
                .buttonStyle(.bordered)
        }
        .padding(24)
        .frame(width: 440, height: 420)
        .task {
            let result = await client.exportProfile(name: profileName)
            content = result
            loaded = true
        }
        .animation(.spring(response: 0.4), value: done)
    }

    private func saveFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(profileName).conf"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? content.write(to: url, atomically: true, encoding: .utf8)
            done = true
        }
    }
}

// MARK: - 手动填写向导

struct WGProfile: Codable {
    var name: String = ""
    // Interface
    var privateKey: String = ""
    var address: String = ""
    var dns: String = ""
    var mtu: Int = 1420
    // Peer
    var publicKey: String = ""
    var presharedKey: String = ""
    var endpoint: String = ""
    var allowedIPs: String = "0.0.0.0/0, ::/0"
    var keepalive: Int = 25
}

struct ManualWizardView: View {
    @State private var step = 0
    @State private var profile = WGProfile()
    let onComplete: (WGProfile) -> Void

    private let steps = ["名称", "本机密钥", "对端信息", "确认"]

    var body: some View {
        VStack(spacing: 0) {
            // 顶部进度指示器
            HStack(spacing: 4) {
                ForEach(0..<steps.count, id: \.self) { i in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(i <= step ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 24, height: 24)
                            .overlay(
                                Group {
                                    if i < step {
                                        Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white)
                                    } else {
                                        Text("\(i + 1)").font(.caption2.bold()).foregroundStyle(i <= step ? .white : .secondary)
                                    }
                                }
                            )
                            .scaleEffect(i == step ? 1.15 : 1.0)
                            .animation(.spring(response: 0.3), value: step)

                        Text(steps[i])
                            .font(.caption)
                            .foregroundStyle(i <= step ? .primary : .secondary)

                        if i < steps.count - 1 {
                            Rectangle()
                                .fill(i < step ? Color.accentColor : Color.secondary.opacity(0.3))
                                .frame(height: 2)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Divider()

            // 步骤内容（带转场动画）
            TabView(selection: $step) {
                // Step 0: 名称
                VStack(spacing: 16) {
                    wizardIcon("person.crop.circle.badge.questionmark")
                    wizardTitle("给你的配置起个名字", "方便后续识别和管理")
                    TextField("如：home-vpn", text: $profile.name)
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                        .frame(maxWidth: 300)
                }
                .tag(0)

                // Step 1: Interface
                VStack(spacing: 12) {
                    wizardIcon("key.fill")
                    wizardTitle("本机密钥信息", "这些信息来自你的 WireGuard 服务端配置")

                    wizardField("Private Key", "本机私钥 (base64)", text: $profile.privateKey, monospaced: true)
                    wizardField("Address", "本机隧道 IP (如 10.66.66.3/24)", text: $profile.address)
                    HStack(spacing: 16) {
                        wizardField("DNS (可选)", "DNS 服务器", text: $profile.dns)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("MTU").font(.caption).foregroundStyle(.secondary)
                            TextField("1420", value: $profile.mtu, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                        }
                    }
                }
                .tag(1)

                // Step 2: Peer
                VStack(spacing: 12) {
                    wizardIcon("network")
                    wizardTitle("对端（服务器）信息", "WireGuard 服务端的连接信息")

                    wizardField("Public Key", "服务器公钥 (base64)", text: $profile.publicKey, monospaced: true)
                    wizardField("Endpoint", "服务器地址 (如 vpn.example.com:51820)", text: $profile.endpoint)
                    wizardField("Allowed IPs", "走隧道的网段", text: $profile.allowedIPs)

                    HStack(spacing: 16) {
                        wizardField("Preshared Key (可选)", "预共享密钥", text: $profile.presharedKey, monospaced: true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Keepalive").font(.caption).foregroundStyle(.secondary)
                            TextField("25", value: $profile.keepalive, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                        }
                    }
                }
                .tag(2)

                // Step 3: 确认
                VStack(spacing: 12) {
                    wizardIcon("checkmark.seal.fill")
                    wizardTitle("确认配置信息", "检查无误后点击保存")

                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            reviewRow("名称", profile.name)
                            Divider()
                            reviewRow("Private Key", String(profile.privateKey.prefix(16)) + "...")
                            reviewRow("Address", profile.address)
                            if !profile.dns.isEmpty { reviewRow("DNS", profile.dns) }
                            reviewRow("MTU", "\(profile.mtu)")
                            Divider()
                            reviewRow("Public Key", String(profile.publicKey.prefix(16)) + "...")
                            reviewRow("Endpoint", profile.endpoint)
                            reviewRow("Allowed IPs", profile.allowedIPs)
                            if !profile.presharedKey.isEmpty {
                                reviewRow("Preshared Key", String(profile.presharedKey.prefix(16)) + "...")
                            }
                            reviewRow("Keepalive", "\(profile.keepalive)s")
                        }
                        .padding(16)
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                .tag(3)
            }
            .animation(.easeInOut(duration: 0.3), value: step)

            Divider()

            // 底部导航
            HStack {
                Button("取消") {}
                    .buttonStyle(.bordered)
                Spacer()
                if step > 0 {
                    Button("上一步") {
                        withAnimation { step -= 1 }
                    }
                    .buttonStyle(.bordered)
                }
                if step < steps.count - 1 {
                    Button("下一步") {
                        withAnimation { step += 1 }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canProceed)
                } else {
                    Button("保存") {
                        onComplete(profile)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
        }
        .frame(width: 560, height: 580)
    }

    private var canProceed: Bool {
        switch step {
        case 0: return !profile.name.isEmpty
        case 1: return !profile.privateKey.isEmpty && !profile.address.isEmpty
        case 2: return !profile.publicKey.isEmpty && !profile.endpoint.isEmpty
        default: return true
        }
    }

    private func wizardIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 44))
            .foregroundStyle(.tint)
            .padding(.bottom, 4)
    }

    private func wizardTitle(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.title3).fontWeight(.semibold)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
    }

    private func wizardField(_ label: String, _ placeholder: String, text: Binding<String>, monospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            if monospaced {
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            } else {
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func reviewRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).font(.caption)
            Spacer()
            Text(value).font(.system(.caption, design: .monospaced))
        }
    }
}
