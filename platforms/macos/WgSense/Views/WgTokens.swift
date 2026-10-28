import AppKit
import Observation
import SwiftUI

// 设计档位：界面里的间距、字号、圆角只准从这里取值，不再写死数字。
//
//   数值存在同目录的 WgTokens.json（随 App 打包）。
//   Debug 版有「布局调节」面板（⌥⌘T）：拖滑块整页实时变化，「保存到工程」写回 WgTokens.json，
//   下次构建 / 发版即生效。scripts/check-tokens.py 拦截新写死的数字。

struct WgTokenSpec: Identifiable {
    let key: String
    let label: String
    let fallback: CGFloat
    let range: ClosedRange<CGFloat>
    var id: String { key }
}

enum WgTokenGroup: String, CaseIterable, Identifiable {
    case space, type, radius, layout
    var id: String { rawValue }
    var title: String {
        switch self {
        case .space: return "间距"
        case .type: return "字号"
        case .radius: return "圆角"
        case .layout: return "版面"
        }
    }
    var step: CGFloat { self == .type ? 0.5 : 1 }
    var specs: [WgTokenSpec] {
        switch self {
        case .space:
            return [
                .init(key: "space.hair", label: "hair · 发丝", fallback: 2, range: 0...6),
                .init(key: "space.xs", label: "xs", fallback: 4, range: 0...10),
                .init(key: "space.s", label: "s", fallback: 8, range: 2...16),
                .init(key: "space.m", label: "m", fallback: 12, range: 4...24),
                .init(key: "space.l", label: "l", fallback: 16, range: 6...32),
                .init(key: "space.xl", label: "xl", fallback: 20, range: 8...40),
                .init(key: "space.xxl", label: "xxl", fallback: 24, range: 10...48),
                .init(key: "space.xxxl", label: "xxxl", fallback: 32, range: 12...64),
            ]
        case .type:
            return [
                .init(key: "type.micro", label: "micro · 角标", fallback: 9, range: 7...12),
                .init(key: "type.caption", label: "caption · 注释", fallback: 11, range: 8...14),
                .init(key: "type.footnote", label: "footnote · 次要", fallback: 12, range: 9...15),
                .init(key: "type.body", label: "body · 正文", fallback: 13, range: 10...17),
                .init(key: "type.sub", label: "sub · 小标题", fallback: 15, range: 11...20),
                .init(key: "type.title", label: "title · 标题", fallback: 17, range: 13...24),
                .init(key: "type.section", label: "section · 区块", fallback: 20, range: 14...30),
                .init(key: "type.large", label: "large · 大字", fallback: 24, range: 16...36),
                .init(key: "type.readout", label: "readout · 读数", fallback: 30, range: 20...44),
                .init(key: "type.page", label: "page · 页标题", fallback: 40, range: 24...60),
                .init(key: "type.display", label: "display · 展示", fallback: 48, range: 28...72),
            ]
        case .radius:
            return [
                .init(key: "radius.s", label: "s · 小件", fallback: 3, range: 0...12),
                .init(key: "radius.m", label: "m · 卡片", fallback: 4, range: 0...16),
            ]
        case .layout:
            // 不归档的具体版面尺寸，每个滑块只管一处。
            return [
                .init(key: "layout.sidebarTop", label: "侧栏顶部留白（让红绿灯）", fallback: 40, range: 0...80),
                .init(key: "layout.pageMaxWidth", label: "页面最大宽度（拉满=贴边）", fallback: 820, range: 600...2400),
            ]
        }
    }
}

@Observable
final class WgTokens {
    static let shared = WgTokens()

    /// 当前生效的数值；界面读这里，调节面板写这里。
    private(set) var values: [String: CGFloat]
    /// 上次保存（或打包自带）的数值，用于「还原」和判断有无改动。
    private(set) var saved: [String: CGFloat]
    /// 参考线：给每处 wgPadding 画出内边距区域和档位标注（仅 Debug）。
    var guides = false

    private init() {
        var loaded: [String: CGFloat] = [:]
        if let url = Bundle.main.url(forResource: "WgTokens", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let raw = try? JSONDecoder().decode([String: Double].self, from: data) {
            loaded = raw.mapValues { CGFloat($0) }
        }
        values = loaded
        saved = loaded
        #if DEBUG
        guides = UserDefaults.standard.bool(forKey: "WgTuneGuides")
        // 脚本 / 自测入口：发分布式通知 com.wgsense.tune.set，userInfo {key, value} 等同拖滑块。
        DistributedNotificationCenter.default().addObserver(forName: .init("com.wgsense.tune.set"), object: nil, queue: .main) { note in
            guard let key = note.userInfo?["key"] as? String, let raw = note.userInfo?["value"] as? String,
                  let v = Double(raw) else { return }
            if key == "guides" { WgTokens.shared.guides = v != 0 } else { WgTokens.shared.set(key, CGFloat(v)) }
        }
        #endif
    }

    static let allSpecs = WgTokenGroup.allCases.flatMap(\.specs)

    subscript(_ key: String) -> CGFloat {
        if let v = values[key] { return v }
        return Self.allSpecs.first { $0.key == key }?.fallback ?? 0
    }

    func set(_ key: String, _ value: CGFloat) { values[key] = value }

    var isDirty: Bool { Self.allSpecs.contains { self[$0.key] != (saved[$0.key] ?? $0.fallback) } }

    func revert() { values = saved }

    func resetToFallback() { values = Dictionary(uniqueKeysWithValues: Self.allSpecs.map { ($0.key, $0.fallback) }) }

    /// 给参考线用：数值 → 档位名（多个档位同值时取第一个）。
    func spaceTier(for value: CGFloat) -> (name: String, index: Int)? {
        let specs = WgTokenGroup.space.specs
        guard let i = specs.firstIndex(where: { self[$0.key] == value }) else { return nil }
        return (String(specs[i].key.dropFirst("space.".count)), i)
    }

    #if DEBUG
    /// 源码里的 WgTokens.json（Debug 构建知道自己的源码位置）。
    static let sourceFile = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("WgTokens.json")

    /// 写回工程里的 WgTokens.json，同时更新运行中 App 的 Resources 副本。
    @discardableResult
    func saveToProject() -> String? {
        let snapshot = Dictionary(uniqueKeysWithValues: Self.allSpecs.map { ($0.key, Double(self[$0.key])) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: Self.sourceFile, options: .atomic)
            if let bundled = Bundle.main.url(forResource: "WgTokens", withExtension: "json") {
                try? data.write(to: bundled, options: .atomic)
            }
            saved = snapshot.mapValues { CGFloat($0) }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
    #endif
}

// MARK: - 档位

enum WgSpace {
    static var hair: CGFloat { WgTokens.shared["space.hair"] }
    static var xs: CGFloat { WgTokens.shared["space.xs"] }
    static var s: CGFloat { WgTokens.shared["space.s"] }
    static var m: CGFloat { WgTokens.shared["space.m"] }
    static var l: CGFloat { WgTokens.shared["space.l"] }
    static var xl: CGFloat { WgTokens.shared["space.xl"] }
    static var xxl: CGFloat { WgTokens.shared["space.xxl"] }
    static var xxxl: CGFloat { WgTokens.shared["space.xxxl"] }
}

enum WgType {
    static var micro: CGFloat { WgTokens.shared["type.micro"] }
    static var caption: CGFloat { WgTokens.shared["type.caption"] }
    static var footnote: CGFloat { WgTokens.shared["type.footnote"] }
    static var body: CGFloat { WgTokens.shared["type.body"] }
    static var sub: CGFloat { WgTokens.shared["type.sub"] }
    static var title: CGFloat { WgTokens.shared["type.title"] }
    static var section: CGFloat { WgTokens.shared["type.section"] }
    static var large: CGFloat { WgTokens.shared["type.large"] }
    static var readout: CGFloat { WgTokens.shared["type.readout"] }
    static var page: CGFloat { WgTokens.shared["type.page"] }
    static var display: CGFloat { WgTokens.shared["type.display"] }
}

enum WgLayout {
    static var sidebarTop: CGFloat { WgTokens.shared["layout.sidebarTop"] }
    /// 内容页最大宽度，超出部分居中留白；拉到上限即铺满窗口。
    static var pageMaxWidth: CGFloat {
        let v = WgTokens.shared["layout.pageMaxWidth"]
        return v >= 2400 ? .infinity : v
    }
}

enum WgRadius {
    static var s: CGFloat { WgTokens.shared["radius.s"] }
    static var m: CGFloat { WgTokens.shared["radius.m"] }
}

// MARK: - 带参考线的内边距

extension View {
    /// 等同 `.padding`；Debug 版打开参考线时会标出这块内边距属于哪一档。
    func wgPadding(_ length: CGFloat) -> some View { modifier(WgPaddingGuide(edges: .all, length: length)) }
    func wgPadding(_ edges: Edge.Set = .all, _ length: CGFloat) -> some View {
        modifier(WgPaddingGuide(edges: edges, length: length))
    }
}

struct WgPaddingGuide: ViewModifier {
    let edges: Edge.Set
    let length: CGFloat

    func body(content: Content) -> some View {
        #if DEBUG
        // 结构保持不变（只在闭包里开关），切换参考线不会重建视图、不丢滚动位置。
        let tokens = WgTokens.shared
        let on = tokens.guides && length > 0
        let tier = on ? tokens.spaceTier(for: length) : nil
        let color = tier.map { Self.palette[$0.index % Self.palette.count] } ?? .red
        content
            .overlay { if on { Rectangle().strokeBorder(color.opacity(0.7), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2])) } }
            .padding(edges, length)
            .background { if on { color.opacity(0.14) } }
            .overlay(alignment: .topLeading) {
                if on {
                    Text(tier.map { "\($0.name) \(Int(length))" } ?? "✕ \(Int(length))")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 2)
                        .background(color.opacity(0.85))
                        .allowsHitTesting(false)
                }
            }
        #else
        content.padding(edges, length)
        #endif
    }

    static let palette: [Color] = [.gray, .teal, .blue, .indigo, .purple, .pink, .orange, .red]
}
