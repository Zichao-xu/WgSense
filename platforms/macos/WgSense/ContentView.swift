import SwiftUI

struct ContentView: View {
    @State private var tunnelStatus: String = "Unknown"
    @State private var isHomeNetwork: Bool = false
    @State private var isPaused: Bool = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("WgSense")
                .font(.largeTitle)

            statusRow(label: "隧道状态", value: tunnelStatus)
            statusRow(label: "在家网段", value: isHomeNetwork ? "是" : "否")
            statusRow(label: "智能管理", value: isPaused ? "已暂停" : "运行中")

            HStack(spacing: 12) {
                Button("连接") {
                    // 阶段 1:调用 Go 核心 tunnel.Connect()
                }
                .buttonStyle(.borderedProminent)

                Button("断开") {
                    // 阶段 1:调用 Go 核心 tunnel.Disconnect()
                }
                .buttonStyle(.bordered)

                Button(isPaused ? "恢复" : "暂停") {
                    // 阶段 1:调用 Go 核心 pause.Toggle()
                    isPaused.toggle()
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 8)

            Spacer()

            Text("阶段 0 骨架 · 阶段 1 接入 Go 核心")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }

    private func statusRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
    }
}

#Preview {
    ContentView()
}
