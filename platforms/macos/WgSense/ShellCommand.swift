import Foundation

struct ShellCommandResult {
    let status: Int32
    let output: String

    var succeeded: Bool { status == 0 }
}

enum ShellCommand {
    static func run(_ launchPath: String, arguments: [String], timeout: TimeInterval = 20) async -> ShellCommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.launchPath = launchPath
                task.arguments = arguments
                let pipe = Pipe()
                task.standardOutput = pipe
                task.standardError = pipe

                do {
                    try task.run()
                    let deadline = Date().addingTimeInterval(timeout)
                    while task.isRunning && Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                    if task.isRunning {
                        task.terminate()
                        Thread.sleep(forTimeInterval: 0.2)
                        if task.isRunning { task.interrupt() }
                    }
                    task.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: ShellCommandResult(status: task.terminationStatus, output: output))
                } catch {
                    continuation.resume(returning: ShellCommandResult(status: -1, output: error.localizedDescription))
                }
            }
        }
    }

    static func sh(_ command: String, timeout: TimeInterval = 20) async -> ShellCommandResult {
        await run("/bin/zsh", arguments: ["-lc", command], timeout: timeout)
    }

    static func administrator(_ shellCommand: String, timeout: TimeInterval = 60) async -> ShellCommandResult {
        let escaped = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        return await run("/usr/bin/osascript", arguments: ["-e", script], timeout: timeout)
    }

    static func quote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
