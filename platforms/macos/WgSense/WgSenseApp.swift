import SwiftUI

@main
struct WgSenseApp: App {
    @StateObject private var client = DaemonClient()

    var body: some Scene {
        // 主窗口：Surge 风格 sidebar + 详情
        WindowGroup {
            MainView()
                .environmentObject(client)
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowStyle(.hiddenTitleBar)

        // 菜单栏：状态 + 快速开关
        MenuBarExtra("WgSense", systemImage: menuBarIcon) {
            MenuBarView()
                .environmentObject(client)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarIcon: String {
        switch client.status?.state {
        case "Connected": return "shield.lefthalf.filled"
        case "Disconnected": return "shield"
        default: return "shield.lefthalf.filled"
        }
    }
}
