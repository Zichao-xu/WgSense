import SwiftUI
import AppKit

enum WgAppLanguage: String, CaseIterable, Identifiable {
    case system
    case zhHans
    case zhHant
    case english
    case japanese
    case korean
    case russian
    case persian
    case arabic
    case turkish
    case vietnamese

    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .system: return "跟随系统"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .english: return "English"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .russian: return "Русский"
        case .persian: return "فارسی"
        case .arabic: return "العربية"
        case .turkish: return "Türkçe"
        case .vietnamese: return "Tiếng Việt"
        }
    }
    var locale: Locale {
        switch self {
        case .system: return .current
        case .zhHans: return Locale(identifier: "zh-Hans")
        case .zhHant: return Locale(identifier: "zh-Hant")
        case .english: return Locale(identifier: "en")
        case .japanese: return Locale(identifier: "ja")
        case .korean: return Locale(identifier: "ko")
        case .russian: return Locale(identifier: "ru")
        case .persian: return Locale(identifier: "fa")
        case .arabic: return Locale(identifier: "ar")
        case .turkish: return Locale(identifier: "tr")
        case .vietnamese: return Locale(identifier: "vi")
        }
    }
}

enum WgAppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// AppDelegate：防止关闭主窗口后应用退出，保证 MenuBarExtra 常驻
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 如果是通过 Finder/单击图标启动，不自动弹窗（菜单栏优先）
        // 保留窗口逻辑由 SwiftUI 管理
    }

    func applicationWillTerminate(_ notification: Notification) {
        DaemonClient.shutdownAppOwnedDaemonSync()
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
                .frame(minWidth: 720, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
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
