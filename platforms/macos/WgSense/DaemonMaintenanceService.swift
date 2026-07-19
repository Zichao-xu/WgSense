import Foundation
import SwiftUI

struct DaemonDiagnostics {
    var generatedAt: Date = Date()
    var apiReachable: Bool = false
    var apiSummary: String = "daemon API 未连接"
    var launchDaemonPlistExists: Bool = false
    var launchDaemonLoaded: Bool = false
    var receiveMoverPlistExists: Bool = false
    var helperInstalled: Bool = false
    var bundledHelperAvailable: Bool = false
    var logFileExists: Bool = false
    var dnsSummary: String = "未检测"
    var processLines: [String] = []
    var routeLines: [String] = []
    var utunLines: [String] = []

    var installedSummary: String {
        launchDaemonPlistExists ? (launchDaemonLoaded ? "已安装并已加载" : "已安装但未加载") : "未安装"
    }

    var permissionSummary: String {
        helperInstalled ? "系统 helper 已存在" : "系统 helper 未安装"
    }

    var residualSummary: String {
        if routeLines.isEmpty && !dnsSummary.contains("10.66.66.1") {
            return "未发现 WgSense 高风险残留"
        }
        return "发现需要检查的 DNS/路由项"
    }

    var exportText: String {
        var lines: [String] = []
        lines.append("WgSense daemon diagnostics")
        lines.append("Generated: \(generatedAt)")
        lines.append("")
        lines.append("API: \(apiSummary)")
        lines.append("System service: \(installedSummary)")
        lines.append("Receive mover plist: \(receiveMoverPlistExists ? "present" : "missing")")
        lines.append("Installed helper: \(helperInstalled ? "present" : "missing")")
        lines.append("Bundled helper: \(bundledHelperAvailable ? "present" : "missing")")
        lines.append("Log file: \(logFileExists ? "present" : "missing")")
        lines.append("DNS: \(dnsSummary)")
        lines.append("")
        lines.append("[Processes]")
        lines.append(contentsOf: processLines.isEmpty ? ["none"] : processLines)
        lines.append("")
        lines.append("[Suspicious routes]")
        lines.append(contentsOf: routeLines.isEmpty ? ["none"] : routeLines)
        lines.append("")
        lines.append("[utun]")
        lines.append(contentsOf: utunLines.isEmpty ? ["none"] : utunLines)
        return lines.joined(separator: "\n")
    }
}

enum MaintenanceAction: String, Identifiable {
    case installSystemHelper
    case uninstallSystemHelper
    case restartSystemHelper
    case cleanupNetworkState

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .installSystemHelper: return "安装系统 helper"
        case .uninstallSystemHelper: return "卸载系统 helper"
        case .restartSystemHelper: return "重启系统服务"
        case .cleanupNetworkState: return "清理残留网络状态"
        }
    }

    var message: LocalizedStringKey {
        switch self {
        case .installSystemHelper:
            return "会安装 WgSense daemon、接收文件搬运 helper 和 launchd 配置，需要管理员授权。"
        case .uninstallSystemHelper:
            return "会停止并删除 WgSense 系统服务与 helper，可保留用户配置和传输数据。"
        case .restartSystemHelper:
            return "会重启 com.wgsense.daemon。若当前正在连接 WireGuard，连接会短暂中断。"
        case .cleanupNetworkState:
            return "会请求 WgSense 断开、清理 WgSense 相关进程、移除 10.66.66.1 DNS 和可识别的 WgSense host route。不会删除 Clash/其他 VPN 的 Fake-IP 路由。"
        }
    }

    var role: String {
        switch self {
        case .installSystemHelper, .restartSystemHelper: return "default"
        case .uninstallSystemHelper, .cleanupNetworkState: return "destructive"
        }
    }
}

struct DaemonMaintenanceService {
    private let controlAPI = DaemonControlAPIClient()

    func diagnostics() async -> DaemonDiagnostics {
        async let api = apiSummary()
        async let plist = fileExists("/Library/LaunchDaemons/com.wgsense.daemon.plist")
        async let moverPlist = fileExists("\(NSHomeDirectory())/Library/LaunchAgents/com.wgsense.receive-mover.plist")
        async let helper = fileExists("/usr/local/libexec/wgsense-daemon")
        async let bundled = bundledDaemonPath() != nil
        async let logFile = fileExists("/var/log/wgsense-daemon.log")
        async let loaded = commandHasOutput("launchctl print system/com.wgsense.daemon 2>/dev/null | head -1")
        async let dns = ShellCommand.sh("networksetup -getdnsservers Wi-Fi 2>/dev/null || true")
        async let processes = ShellCommand.sh("ps ax -o pid,command | /usr/bin/grep -E 'wgsense|wireguard-go' | /usr/bin/grep -v grep || true")
        async let routes = ShellCommand.sh("netstat -rn -f inet | /usr/bin/grep -E '^(default|0/1|128\\.0/1|10\\.66|198\\.18|198\\.19)' || true")
        async let utuns = ShellCommand.sh("ifconfig | /usr/bin/grep -E '^(utun[0-9]+:|\\tinet )' || true")

        let apiResult = await api
        var result = DaemonDiagnostics()
        result.apiReachable = apiResult.reachable
        result.apiSummary = apiResult.summary
        result.launchDaemonPlistExists = await plist
        result.launchDaemonLoaded = await loaded
        result.receiveMoverPlistExists = await moverPlist
        result.helperInstalled = await helper
        result.bundledHelperAvailable = await bundled
        result.logFileExists = await logFile
        result.dnsSummary = cleanLines((await dns).output).joined(separator: " / ")
        result.processLines = cleanLines((await processes).output)
        result.routeLines = cleanLines((await routes).output)
        result.utunLines = cleanLines((await utuns).output)
        return result
    }

    func perform(_ action: MaintenanceAction) async -> ShellCommandResult {
        switch action {
        case .installSystemHelper:
            return await installSystemHelper()
        case .uninstallSystemHelper:
            return await runPackagedScript("wgsense-uninstall-services.sh", timeout: 60)
        case .restartSystemHelper:
            return await ShellCommand.administrator(
                "launchctl kickstart -k system/com.wgsense.daemon",
                timeout: 30
            )
        case .cleanupNetworkState:
            return await cleanupNetworkState()
        }
    }

    func exportDiagnostics(_ diagnostics: DaemonDiagnostics, to url: URL) throws {
        try diagnostics.exportText.write(to: url, atomically: true, encoding: .utf8)
    }

    func exportDaemonLog(to url: URL) async -> ShellCommandResult {
        let destination = ShellCommand.quote(url.path)
        let command = """
        if [[ -r /var/log/wgsense-daemon.log ]]; then
          /bin/cp /var/log/wgsense-daemon.log \(destination)
        else
          echo 'WgSense daemon log is missing or not readable.' > \(destination)
        fi
        """
        return await ShellCommand.sh(command, timeout: 10)
    }

    private func installSystemHelper() async -> ShellCommandResult {
        guard let daemon = bundledDaemonPath() else {
            return ShellCommandResult(status: -1, output: "App bundle 内缺少 wgsense-daemon")
        }
        guard let script = packagedScriptPath("wgsense-install-services.sh") else {
            return ShellCommandResult(status: -1, output: "App bundle 内缺少安装脚本")
        }
        guard let mover = packagedScriptPath("wgsense-receive-mover.sh") else {
            return ShellCommandResult(status: -1, output: "App bundle 内缺少接收搬运脚本")
        }
        let command = "\(ShellCommand.quote(script)) \(ShellCommand.quote(daemon)) \(ShellCommand.quote(mover))"
        return await ShellCommand.administrator(command, timeout: 90)
    }

    private func cleanupNetworkState() async -> ShellCommandResult {
        let command = """
        set -u
        /usr/bin/curl -fsS -X POST http://127.0.0.1:8765/api/disconnect >/dev/null 2>&1 || true
        /usr/bin/pkill -TERM -f '/usr/local/libexec/wgsense-daemon' 2>/dev/null || true
        /usr/bin/pkill -TERM -f 'wgsense-daemon.*--app-owned=true' 2>/dev/null || true
        /sbin/route -n delete -host 10.66.66.1 >/dev/null 2>&1 || true
        while IFS= read -r service; do
          [[ -z "$service" ]] && continue
          dns="$(/usr/sbin/networksetup -getdnsservers "$service" 2>/dev/null || true)"
          if printf '%s\\n' "$dns" | /usr/bin/grep -qx '10.66.66.1'; then
            /usr/sbin/networksetup -setdnsservers "$service" Empty
          fi
        done < <(/usr/sbin/networksetup -listallnetworkservices 2>/dev/null | /usr/bin/sed '/^An asterisk/d')
        echo "WgSense cleanup completed. Review diagnostics for any remaining split routes."
        """
        return await ShellCommand.administrator(command, timeout: 60)
    }

    private func runPackagedScript(_ name: String, timeout: TimeInterval) async -> ShellCommandResult {
        guard let script = packagedScriptPath(name) else {
            return ShellCommandResult(status: -1, output: "App bundle 内缺少 \(name)")
        }
        return await ShellCommand.administrator(ShellCommand.quote(script), timeout: timeout)
    }

    private func apiSummary() async -> (reachable: Bool, summary: String) {
        do {
            let status = try await controlAPI.status(timeout: 1.5)
            let owner = status.app_owned == true ? "App 临时服务" : "系统/外部服务"
            let mode = status.passive == true ? "被动" : "网络管理"
            return (true, "\(owner) / \(mode) / \(status.state)")
        } catch {
            return (false, "daemon API 未连接")
        }
    }

    private func fileExists(_ path: String) async -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    private func commandHasOutput(_ command: String) async -> Bool {
        !cleanLines((await ShellCommand.sh(command, timeout: 5)).output).isEmpty
    }

    private func bundledDaemonPath() -> String? {
        Bundle.main.path(forResource: "wgsense-daemon", ofType: nil, inDirectory: "libexec")
    }

    private func packagedScriptPath(_ name: String) -> String? {
        Bundle.main.path(forResource: name, ofType: nil, inDirectory: "packaging")
    }

    private func cleanLines(_ output: String) -> [String] {
        output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
