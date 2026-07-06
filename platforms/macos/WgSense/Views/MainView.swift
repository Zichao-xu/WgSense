import SwiftUI

// 主窗口：左侧 sidebar 导航 + 右侧详情。Surge 风格。
struct MainView: View {
    @EnvironmentObject var client: DaemonClient
    @State private var selection: SidebarItem? = .overview

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            if let sel = selection {
                switch sel {
                case .overview:
                    OverviewView()
                case .wireguard:
                    WireGuardView()
                case .transfer:
                    PlaceholderView(title: "传输", icon: "arrow.triangle.2.circlepath", desc: "局域网文件传输（LocalSend 类）")
                case .proxy:
                    PlaceholderView(title: "代理", icon: "globe.asia.australia", desc: "mihomo 热备本机代理")
                case .logs:
                    LogsView()
                case .settings:
                    SettingsView()
                }
            } else {
                OverviewView()
            }
        }
        .task { await client.refresh() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            Task { await client.fetchStatus() }
        }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview, wireguard, transfer, proxy, logs, settings
    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview: return "概览"
        case .wireguard: return "WireGuard"
        case .transfer: return "传输"
        case .proxy: return "代理"
        case .logs: return "日志"
        case .settings: return "设置"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .wireguard: return "shield.lefthalf.filled"
        case .transfer: return "arrow.triangle.2.circlepath"
        case .proxy: return "globe.asia.australia"
        case .logs: return "doc.text"
        case .settings: return "gear"
        }
    }
}

struct SidebarView: View {
    @Binding var selection: SidebarItem?

    var body: some View {
        List(SidebarItem.allCases, selection: $selection) { item in
            Label(item.label, systemImage: item.icon)
                .tag(item)
        }
        .listStyle(.sidebar)
    }
}
