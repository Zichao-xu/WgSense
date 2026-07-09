import SwiftUI
import AppKit

// AppDelegate：防止关闭主窗口后应用退出，保证 MenuBarExtra 常驻
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 如果是通过 Finder/单击图标启动，不自动弹窗（菜单栏优先）
        // 保留窗口逻辑由 SwiftUI 管理
    }
}

@main
struct WgSenseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var client = DaemonClient()

    var body: some Scene {
        // 主窗口：Surge 风格 sidebar + 详情
        WindowGroup(id: "main") {
            MainView()
                .environmentObject(client)
                .frame(minWidth: 720, minHeight: 480)
                .alert("操作失败", isPresented: Binding(
                    get: { client.alertMsg != nil },
                    set: { if !$0 { client.alertMsg = nil } }
                )) {
                    Button("确定", role: .cancel) { client.alertMsg = nil }
                } message: {
                    Text(client.alertMsg ?? "")
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 900, height: 600)

        // 菜单栏：状态 + 快速开关
        MenuBarExtra {
            MenuBarView()
                .environmentObject(client)
        } label: {
            // 用 Label 渲染：图标 + 隐藏文字（辅助功能可读）
            Label("WgSense", systemImage: menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }

    // 菜单栏图标：填充样式确保高对比度；连接/断开状态区分明显
    private var menuBarIcon: String {
        switch client.status?.state {
        case "Connected": return "shield.fill"
        case "Disconnected": return "shield.slash.fill"
        default: return "shield.lefthalf.filled"
        }
    }
}
