import SwiftUI
import UniformTypeIdentifiers

// 按提供商分组（P-G12）与订阅通配符分类（P-V04）的界面。

/// 组卡片里“节点根据提供商分组”：每个提供商（或其分类）一段，折叠态每段一行预览点。
struct PPProviderSectionsView: View {
    @EnvironmentObject private var store: ProxyPanelStore
    var group: String
    var names: [String]
    var previewOnly: Bool
    var onSelect: (String) -> Void

    var body: some View {
        let now = store.proxyMap[group]?.now
        VStack(alignment: .leading, spacing: previewOnly ? 8 : 14) {
            ForEach(store.providerSections(of: names)) { section in
                VStack(alignment: .leading, spacing: 6) {
                    if !section.title.isEmpty {
                        HStack(spacing: 6) {
                            Text(verbatim: section.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if !previewOnly {
                                PPCategoryTestButton(scope: group, nodes: section.proxies,
                                                     displayName: "\(group) / \(section.title)",
                                                     keyName: "\(group)::\(section.id)")
                            }
                        }
                    }
                    if previewOnly {
                        PPPreview(nodes: section.proxies, now: now, group: group, onSelect: onSelect)
                    } else {
                        PPNodeGrid(group: group, names: section.proxies)
                    }
                }
            }
        }
    }
}

/// 分类/分段测速按钮（带测速中状态）。
struct PPCategoryTestButton: View {
    @EnvironmentObject private var store: ProxyPanelStore
    var scope: String
    var nodes: [String]
    var displayName: String
    var keyName: String

    var body: some View {
        Button {
            Task { await store.testNodes(scope: scope, nodes: nodes, displayName: displayName, keyName: keyName) }
        } label: {
            if store.isTesting("nodes:\(keyName)") {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "bolt.fill").font(.system(size: 10))
            }
        }
        .buttonStyle(WgToolbarIconButtonStyle())
        .help("测速")
    }
}

/// 订阅卡片的分类控件：通配符输入 + 分类开关 + 全部折叠/展开。
struct PPCategoryControls: View {
    @EnvironmentObject private var store: ProxyPanelStore
    var provider: String
    @State private var draft = ""

    var body: some View {
        let enabled = store.categoryEnabledMap[provider] == true
        let active = store.categoryActive(provider: provider)
        HStack(spacing: 6) {
            TextField("通配符", text: $draft)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .frame(width: 90)
                .onSubmit { commit() }
                .help("输入通配符，节点会依据通配符前面的字符来分类。")
            Button(enabled ? "取消" : "分类") {
                commit()
                store.categoryEnabledMap[provider] = !enabled
            }
            .buttonStyle(WgPillButtonStyle())
            .font(.system(size: 11, weight: .medium))
            if active {
                let names = store.providers.first { $0.name == provider }?.proxies.map(\.name) ?? []
                let keys = store.categoryGroups(provider: provider, proxies: names).map { "\(provider)::\($0.name)" }
                let anyExpanded = keys.contains { store.categoryCollapseMap[$0] != true }
                Button {
                    var map = store.categoryCollapseMap
                    keys.forEach { map[$0] = anyExpanded }
                    withAnimation(WgDesign.spring) { store.categoryCollapseMap = map }
                } label: {
                    Image(systemName: anyExpanded ? "chevron.up.2" : "chevron.down.2")
                }
                .buttonStyle(WgToolbarIconButtonStyle())
                .help(anyExpanded ? "全部折叠" : "全部展开")
            }
        }
        .onAppear { draft = store.categoryWildcardMap[provider] ?? "" }
    }

    private func commit() {
        store.categoryWildcardMap[provider] = draft.trimmingCharacters(in: .whitespaces)
    }
}

/// 订阅卡片展开后的分类区块：可折叠、可拖拽排序、每类单独测速、显示可用数。
struct PPCategorySections: View {
    @EnvironmentObject private var store: ProxyPanelStore
    var provider: String
    var names: [String]
    @State private var dragging: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(store.categoryGroups(provider: provider, proxies: names).enumerated()), id: \.element.id) { index, category in
                let key = "\(provider)::\(category.name)"
                let collapsed = store.categoryCollapseMap[key] == true
                VStack(alignment: .leading, spacing: 8) {
                    if index > 0 { Divider() }
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                            .onDrag {
                                dragging = category.name
                                return NSItemProvider(object: category.name as NSString)
                            }
                            .help("拖拽排序")
                        Text(verbatim: category.name)
                            .font(.system(size: 12, weight: .semibold))
                        Text(verbatim: "(\(category.available)/\(category.total))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        PPCategoryTestButton(scope: provider, nodes: category.proxies,
                                             displayName: "\(provider) / \(category.name)", keyName: key)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(collapsed ? -90 : 0))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(WgDesign.spring) { store.categoryCollapseMap[key] = !collapsed }
                    }
                    if !collapsed {
                        PPNodeGrid(group: provider, names: category.proxies)
                    }
                }
                .padding(.vertical, 6)
                .onDrop(of: [.text], delegate: CategoryDropDelegate(target: category.name, provider: provider,
                                                                    dragging: $dragging, store: store))
            }
        }
    }
}

private struct CategoryDropDelegate: DropDelegate {
    var target: String
    var provider: String
    @Binding var dragging: String?
    var store: ProxyPanelStore

    func dropEntered(info: DropInfo) {
        guard let from = dragging, from != target else { return }
        withAnimation(WgDesign.spring) { store.moveCategory(provider: provider, from: from, to: target) }
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
