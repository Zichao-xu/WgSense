import SwiftUI

// 测速台页面（规格 §8）：骨架恒定，只往里填数。
//
//   场景栏 → 接线条（A 执行端 ─ B 路径 → C 目标）→ 双表盘 → 台账四格 → 抽屉（曲线 / 参数 / 历史 / 测速源 / 端点）

struct SpeedLabView: View {
    @ObservedObject private var lab = SpeedLabStore.shared

    @State private var tail = false

    var body: some View {
        WgPage(title: "测速", word: "SPEED LAB", maxWidth: 1600) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .bottom, spacing: 18) {
                    sceneBar
                }
                wiring
                hud
                SLDrawer(key: "curve", title: "全程曲线", code: "CRV") { SLCurve(lab: lab) }
                SLDrawer(key: "params", title: "参数", code: "PRM") { SLParamsForm(lab: lab) }
                SLDrawer(key: "history", title: "历史", code: "LOG", badge: lab.history.isEmpty ? "" : "\(lab.history.count)") {
                    SLHistoryList(lab: lab)
                }
                SLDrawer(key: "sources", title: "测速源", code: "SRC") { SLSourcesForm(lab: lab) }
                SLDrawer(key: "endpoints", title: "端点", code: "EP", badge: "\(lab.endpoints.count)") { SLEndpointsForm(lab: lab) }
            }
        }
        .onAppear { lab.discoverPeersIfNeeded() }
        // 测完再刷 1 秒：让收尾的闪入（0 → ⅓ → ⅔ → 1）播完，之后彻底静止
        .task(id: lab.finishedAt) {
            guard lab.finishedAt != nil else { return }
            tail = true
            try? await Task.sleep(for: .seconds(1.2))
            tail = false
        }
    }

    // MARK: HUD

    /// 测速中按 24fps 推进画面时钟；空闲时暂停，零开销。
    private var hud: some View {
        TimelineView(.animation(minimumInterval: 1 / SLMotion.fps, paused: !(lab.running || tail))) { timeline in
            SLHUD(data: SLHUDData(lab), now: timeline.date)
        }
        .overlay {
            GeometryReader { geo in
                let s = geo.size.width / SLHUD.size.width
                startButton
                    .frame(width: 150 * s, height: 34 * s)
                    .position(x: 640 * s, y: 672 * s)
            }
        }
        .clipShape(ChamferShape(WgInk.cutPanel))
    }

    /// START / STOP：HUD 里唯一的主操作。
    private var startButton: some View {
        Button {
            if lab.running { lab.stop() } else { lab.start() }
        } label: {
            Text(verbatim: lab.running ? "STOP" : "START")
                .font(.system(size: 15, weight: .bold, design: .monospaced)).tracking(4)
                .foregroundStyle(Color(red: 0.06, green: 0.063, blue: 0.07))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ChamferShape(tl: 0, tr: 10, br: 0, bl: 10).fill(Color(white: 0.95)))
        }
        .buttonStyle(.plain)
        .disabled(!lab.running && lab.blocker != nil)
        .keyboardShortcut(.return, modifiers: .command)
        .help(lab.target?.isPublic == true && !lab.running ? "将占满宽带约 \(lab.params.duration * (lab.params.directions == .both ? 2 : 1) + 8) 秒" : "")
    }

    // MARK: 场景栏

    private var sceneBar: some View {
        HStack(spacing: 6) {
            Text(verbatim: "SCENE").font(WgInk.mono(10, .medium)).tracking(1.6).foregroundStyle(WgInk.ink3)
                .padding(.trailing, 4)
            ForEach(lab.scenes) { scene in
                Button(scene.title) { withAnimation(WgDesign.spring) { lab.apply(scene) } }
                    .buttonStyle(SLChipStyle(selected: lab.isCurrent(scene)))
                    .disabled(lab.running)
                    .contextMenu {
                        if !scene.builtIn { Button("删除场景", role: .destructive) { lab.deleteScene(scene) } }
                    }
            }
            if !lab.scenes.contains(where: lab.isCurrent), lab.blocker == nil {
                Button { lab.saveCurrentAsScene() } label: { Label("存为场景", systemImage: "plus") }
                    .buttonStyle(SLChipStyle(selected: false))
                    .disabled(lab.running)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: 接线条

    private var wiring: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 0) {
                SLSelector(code: "A", title: "执行端", value: lab.runner?.name ?? "—", detail: lab.runner?.address ?? "") {
                    ForEach(lab.runners) { ep in
                        Button { lab.runnerID = ep.id } label: { Text(verbatim: "\(ep.name)  ·  \(ep.origin)") }
                    }
                }
                SLWire(arrow: false)
                SLSelector(code: "B", title: "路径",
                           value: lab.pathSelectable ? lab.path.title : "按地址",
                           detail: lab.pathSelectable ? (lab.path == .direct ? "绑物理网卡 · 真 DNS" : "系统路由与 DNS") : "iperf3",
                           enabled: lab.pathSelectable) {
                    ForEach(SLPathMode.allCases) { mode in
                        Button(mode.title) { lab.path = mode }
                    }
                }
                SLWire(arrow: true)
                SLSelector(code: "C", title: "目标", value: lab.target?.name ?? "—", detail: lab.target?.address ?? "") {
                    ForEach(lab.endpoints) { ep in
                        Button { lab.targetID = ep.id } label: { Text(verbatim: "\(ep.name)  ·  \(ep.origin)") }
                    }
                }
            }
            .disabled(lab.running)
            Text(verbatim: lab.blocker ?? (lab.target?.kind == .peer ? "WG peer 不能远程登录：要求它自己开着 iperf3 服务端（端口 \(lab.params.iperfPort)）" : " "))
                .font(WgInk.mono(10)).foregroundStyle(lab.blocker == nil ? WgInk.ink3 : WgInk.warn)
        }
    }

    static func linkText(_ raw: String) -> String {
        let parts = raw.split(separator: " ")
        guard let v = parts.first.flatMap({ Int($0) }) else { return raw }
        let speed = v >= 1000 && v % 1000 == 0 ? "\(v / 1000)G" : (v >= 1000 ? String(format: "%.1fG", Double(v) / 1000) : "\(v)M")
        let rest = parts.dropFirst().joined(separator: " ")
        let duplex = rest == "full" ? "全双工" : rest == "half" ? "半双工" : rest
        return [speed, duplex].filter { !$0.isEmpty }.joined(separator: " ")
    }

}

// MARK: - 部件

/// 场景小签：选中 = 白色弱玻璃，其余发丝框。
struct SLChipStyle: ButtonStyle {
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? WgInk.ink : WgInk.ink3)
            .padding(.horizontal, 10).frame(height: 22)
            .background {
                if selected {
                    Color.clear.wgGlassAccent(ChamferShape(tr: 6))
                } else {
                    ChamferShape(tr: 6).strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// 接线条上的一个选择器：代号 / 标题小字 + 值 + 地址注记。
struct SLSelector<Items: View>: View {
    var code: String
    var title: String
    var value: String
    var detail: String
    var enabled = true
    @ViewBuilder var items: () -> Items

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: "\(code) / \(title)").font(WgInk.mono(10, .medium)).tracking(1.2).foregroundStyle(WgInk.ink3)
            Menu {
                items()
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: value).font(.system(size: 12, weight: .medium)).foregroundStyle(WgInk.ink2).lineLimit(1)
                        Text(verbatim: detail.isEmpty ? " " : detail).font(WgInk.mono(9.5)).foregroundStyle(WgInk.ink3).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(WgInk.ink3)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(ChamferShape(tr: WgInk.cutControl).strokeBorder(Color.primary.opacity(enabled ? 0.16 : 0.08), lineWidth: 1))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.55)
        }
        .frame(maxWidth: .infinity)
    }
}

/// 两个选择器之间的接线：发丝线（+ 箭头）。
private struct SLWire: View {
    var arrow: Bool
    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color.primary.opacity(0.35)).frame(height: 1)
            if arrow { Image(systemName: "arrowtriangle.right.fill").font(.system(size: 6)).foregroundStyle(Color.primary.opacity(0.5)) }
        }
        .frame(width: 26)
        .padding(.bottom, 22)
    }
}

/// 抽屉：默认收起，展开状态按 key 记住。
struct SLDrawer<Content: View>: View {
    var key: String
    var title: String
    var code: String
    var badge: String = ""
    @ViewBuilder var content: () -> Content
    @AppStorage private var open: Bool

    init(key: String, title: String, code: String, badge: String = "", @ViewBuilder content: @escaping () -> Content) {
        self.key = key; self.title = title; self.code = code; self.badge = badge; self.content = content
        _open = AppStorage(wrappedValue: false, "speedLab.drawer.\(key)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(WgDesign.spring) { open.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0)).foregroundStyle(WgInk.ink3)
                    WgTagBox(code: code, title: LocalizedStringKey(title))
                    if !badge.isEmpty { Text(verbatim: badge).font(WgInk.mono(10)).foregroundStyle(WgInk.ink3) }
                    WgRuler(opacity: 0.25)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                content()
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .wgPanel(marks: false)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - 全程曲线

/// 下行虚点线、上行实线，单色墨；跑完后就是整次测量的全程图。
struct SLCurve: View {
    @ObservedObject var lab: SpeedLabStore

    var body: some View {
        let down = lab.downSeries.isEmpty ? (lab.lastForCurrent?.downSeries ?? []) : lab.downSeries
        let up = lab.upSeries.isEmpty ? (lab.lastForCurrent?.upSeries ?? []) : lab.upSeries
        let top = max(1, (down + up).max() ?? 1) * 1.1
        VStack(alignment: .leading, spacing: 6) {
            Canvas { ctx, size in
                let tick = lab.downSeries.isEmpty && lab.upSeries.isEmpty ? (lab.lastForCurrent?.tick ?? 1) : lab.tick
                let n = max(Int(Double(lab.params.duration) / tick), down.count, up.count, 2)
                for f in [0.0, 0.5, 1.0] {
                    var g = Path()
                    let y = size.height * (1 - f)
                    g.move(to: CGPoint(x: 0, y: y)); g.addLine(to: CGPoint(x: size.width, y: y))
                    ctx.stroke(g, with: .color(Color.primary.opacity(0.12)), style: StrokeStyle(lineWidth: 0.5, dash: [1, 4]))
                    ctx.draw(Text(verbatim: SLFormat.compact(top * f, unit: lab.params.unit)).font(.system(size: 9, design: .monospaced))
                        .foregroundColor(Color.primary.opacity(0.4)), at: CGPoint(x: 4, y: max(6, y - 6)), anchor: .leading)
                }
                func line(_ series: [Double], dash: [CGFloat], half: Int) {
                    guard series.count > 1 else { return }
                    var p = Path()
                    let width = size.width / 2
                    for (i, v) in series.enumerated() {
                        let x = CGFloat(half) * width + width * CGFloat(i) / CGFloat(n - 1)
                        let y = size.height * (1 - CGFloat(v / top))
                        i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
                    }
                    ctx.stroke(p, with: .color(.primary), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: dash))
                }
                line(down, dash: [2, 2.5], half: 0)
                line(up, dash: [], half: 1)
                var mid = Path()
                mid.move(to: CGPoint(x: size.width / 2, y: 0)); mid.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                ctx.stroke(mid, with: .color(Color.primary.opacity(0.18)), lineWidth: 0.5)
            }
            .frame(height: 130)
            HStack {
                Text(verbatim: "↓ 下行 ┄").font(WgInk.mono(9.5)).foregroundStyle(WgInk.ink3)
                Spacer()
                Text(verbatim: "↑ 上行 ─").font(WgInk.mono(9.5)).foregroundStyle(WgInk.ink3)
            }
        }
    }
}

// MARK: - 参数

struct SLParamsForm: View {
    @ObservedObject var lab: SpeedLabStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("方向") {
                Picker("", selection: $lab.params.directions) {
                    ForEach(SLDirections.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
            row("单位") {
                Picker("", selection: $lab.params.unit) {
                    ForEach(SLUnit.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 140)
            }
            stepper("每个方向时长", value: $lab.params.duration, range: 5...60, suffix: "秒")
            stepper("HTTP 下行线程", value: $lab.params.httpDownThreads, range: 1...32, suffix: "")
            stepper("HTTP 上行线程", value: $lab.params.httpUpThreads, range: 1...16, suffix: "")
            stepper("iperf3 并发流", value: $lab.params.iperfStreams, range: 1...32, suffix: "")
            stepper("iperf3 端口", value: $lab.params.iperfPort, range: 1024...65000, suffix: "")
            Text(verbatim: "iperf3 端口被占会自动顺延（最多 +9）；对端缺 iperf3 时临时部署静态版，测完删除。")
                .font(WgInk.mono(9.5)).foregroundStyle(WgInk.ink3)
        }
        .disabled(lab.running)
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ control: () -> C) -> some View {
        HStack {
            Text(verbatim: title).font(.system(size: 12)).foregroundStyle(WgInk.ink2)
            Spacer()
            control()
        }
    }

    private func stepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, suffix: String) -> some View {
        row(title) {
            Stepper(value: value, in: range) {
                Text(verbatim: "\(value.wrappedValue) \(suffix)").font(.system(size: 12, design: .monospaced))
            }
        }
    }
}

// MARK: - 历史

struct SLHistoryList: View {
    @ObservedObject var lab: SpeedLabStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if lab.history.isEmpty {
                Text("还没有测速记录").font(.system(size: 12)).foregroundStyle(WgInk.ink3)
            } else {
                SLHistoryStrip(history: lab.history, unit: lab.params.unit).padding(.bottom, 10)
                ForEach(lab.history.prefix(30)) { r in
                    HStack(spacing: 10) {
                        Text(verbatim: r.date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).hour().minute()))
                            .font(WgInk.mono(10)).foregroundStyle(WgInk.ink3).frame(width: 92, alignment: .leading)
                        Text(verbatim: "\(r.runner) → \(r.target) · \(r.path)").font(.system(size: 12)).lineLimit(1)
                        Spacer()
                        if let error = r.error {
                            Text(verbatim: error).font(WgInk.mono(10)).foregroundStyle(WgInk.alert).lineLimit(1)
                        } else {
                            Text(verbatim: "↓\(SLFormat.compact(r.down?.stable, unit: lab.params.unit))  ↑\(SLFormat.compact(r.up?.stable, unit: lab.params.unit))")
                                .font(.system(size: 12, design: .monospaced))
                            Text(verbatim: SpeedLabView.linkText(r.linkText)).font(WgInk.mono(10))
                                .foregroundStyle((r.linkMbps ?? 1000) <= 100 && !r.linkText.contains("Wi-Fi") ? WgInk.alert : WgInk.ink3)
                                .frame(width: 84, alignment: .trailing)
                        }
                    }
                    .padding(.vertical, 5)
                    .overlay(alignment: .bottom) { Rectangle().fill(WgInk.rule).frame(height: 1) }
                }
                HStack {
                    Spacer()
                    Button("清空历史", role: .destructive) { lab.clearHistory() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(WgInk.ink3)
                }.padding(.top, 8)
            }
        }
    }
}

/// 历史点阵：每次测量一个点（下行稳定值），网口降速那次圈出来。
struct SLHistoryStrip: View {
    var history: [SLResult]
    var unit: SLUnit

    var body: some View {
        let points = Array(history.prefix(60).reversed()).filter { $0.down != nil }
        let top = max(1, points.compactMap { $0.down?.stable }.max() ?? 1)
        Canvas { ctx, size in
            guard !points.isEmpty else { return }
            let step = size.width / CGFloat(max(points.count - 1, 1))
            for (i, r) in points.enumerated() {
                let v = r.down?.stable ?? 0
                let c = CGPoint(x: points.count == 1 ? size.width / 2 : CGFloat(i) * step, y: size.height - 4 - (size.height - 8) * CGFloat(v / top))
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)), with: .color(Color.primary.opacity(0.7)))
                if let link = r.linkMbps, link <= 100, !r.linkText.contains("Wi-Fi") {
                    ctx.stroke(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)), with: .color(WgInk.alert), lineWidth: 1)
                }
            }
        }
        .frame(height: 44)
    }
}

// MARK: - 测速源

struct SLSourcesForm: View {
    @ObservedObject var lab: SpeedLabStore
    @ObservedObject private var catalog = SLSourceCatalog.shared
    @State private var newDown = ""
    @State private var newUp = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 远程源列表：节点失效时改远程文件，不用发版
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: "源列表").font(.system(size: 12, weight: .semibold))
                HStack {
                    TextField("https://gist.githubusercontent.com/…/raw/sources.json", text: $catalog.url)
                        .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                        .onSubmit { Task { await catalog.refresh() } }
                    Button(catalog.fetching ? "拉取中…" : "拉取") { Task { await catalog.refresh() } }
                        .disabled(catalog.fetching || catalog.url.isEmpty)
                }
                Text(verbatim: status).font(WgInk.mono(9.5)).foregroundStyle(catalog.fetchError == nil ? WgInk.ink3 : WgInk.warn)
            }
            group("↓ 下行", remote: catalog.file?.download ?? [], manual: $lab.downloadSources, draft: $newDown)
            group("↑ 上行", remote: catalog.file?.upload ?? [], manual: $lab.uploadSources, draft: $newUp)
        }
        .disabled(lab.running)
    }

    private var status: String {
        if let e = catalog.fetchError { return e }
        guard let f = catalog.file else { return catalog.url.isEmpty ? "未配置" : "还没拉取过" }
        var parts = ["\(f.download.count) 下行 · \(f.upload.count) 上行"]
        if let u = f.updated { parts.append("列表更新于 \(u)") }
        if let t = catalog.fetchedAt { parts.append("拉取于 " + t.formatted(.relative(presentation: .named))) }
        return parts.joined(separator: " · ")
    }

    private func group(_ title: String, remote: [SLCatalogFile.Entry], manual: Binding<[String]>, draft: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: title).font(.system(size: 12, weight: .semibold))
            ForEach(remote, id: \.self) { e in sourceRow(e.url, note: e.note, removable: nil) }
            ForEach(manual.wrappedValue, id: \.self) { u in
                sourceRow(u, note: "手动", removable: { manual.wrappedValue.removeAll { $0 == u } })
            }
            HStack {
                TextField("手动添加 https://…", text: draft).textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                Button("添加") {
                    let url = draft.wrappedValue.trimmingCharacters(in: .whitespaces)
                    guard url.hasPrefix("http"), !url.contains(" "), !manual.wrappedValue.contains(url) else { return }
                    manual.wrappedValue.append(url)
                    draft.wrappedValue = ""
                }
            }
        }
    }

    /// 一行源：地址 · 备注 · 健康（上次实测 / 连续失败 / 已跳过）。
    private func sourceRow(_ url: String, note: String?, removable: (() -> Void)?) -> some View {
        let h = catalog.health[url], retired = catalog.isRetired(url)
        return HStack(spacing: 8) {
            Text(verbatim: URL(string: url)?.host ?? url).font(.system(size: 11, design: .monospaced))
                .foregroundStyle(retired ? WgInk.ink4 : WgInk.ink2).lineLimit(1).help(url)
            if let note { Text(verbatim: note).font(WgInk.mono(9.5)).foregroundStyle(WgInk.ink3).lineLimit(1) }
            Spacer()
            Group {
                if retired {
                    Button("已跳过 · 重试") { catalog.resetHealth(url) }.buttonStyle(.plain).foregroundStyle(WgInk.warn)
                } else if let h, h.fails > 0 {
                    Text(verbatim: "失败 \(h.fails) 次").foregroundStyle(WgInk.warn)
                } else if let mb = h?.lastMbps, let t = h?.lastOK {
                    Text(verbatim: "\(Int(mb)) Mbps · " + t.formatted(.relative(presentation: .named)))
                } else {
                    Text(verbatim: "未测")
                }
            }
            .font(WgInk.mono(9.5)).foregroundStyle(WgInk.ink3)
            if let removable {
                Button(action: removable) { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(WgInk.ink3)
            }
        }
    }
}

// MARK: - 端点

struct SLEndpointsForm: View {
    @ObservedObject var lab: SpeedLabStore
    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var user = "root"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lab.endpoints) { ep in
                HStack(spacing: 10) {
                    Text(verbatim: ep.name).font(.system(size: 12, weight: .semibold)).frame(width: 140, alignment: .leading).lineLimit(1)
                    Text(verbatim: ep.address).font(.system(size: 11, design: .monospaced)).foregroundStyle(WgInk.ink2).lineLimit(1)
                    Spacer()
                    Text(verbatim: ep.origin + (ep.canRun ? " · 可执行" : " · 仅目标")).font(WgInk.mono(9.5)).foregroundStyle(WgInk.ink3)
                    if ep.origin == "手动添加" {
                        Button { lab.removeManual(ep) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain).foregroundStyle(WgInk.ink3)
                    }
                }
                .padding(.vertical, 3)
            }
            Rectangle().fill(WgInk.rule).frame(height: 1).padding(.vertical, 6)
            Text(verbatim: "添加 SSH 主机（用这台 Mac 的 SSH 公钥登录，不保存密码）").font(.system(size: 12, weight: .semibold))
            HStack {
                TextField("名称", text: $name).frame(width: 110)
                TextField("主机 / IP", text: $host)
                TextField("端口", text: $port).frame(width: 56)
                TextField("用户", text: $user).frame(width: 80)
                Button("添加") {
                    let h = host.trimmingCharacters(in: .whitespaces)
                    guard !h.isEmpty, let p = Int(port), (1...65535).contains(p) else { return }
                    lab.addManual(name: name.trimmingCharacters(in: .whitespaces), host: h, port: p,
                                  user: user.isEmpty ? "root" : user)
                    name = ""; host = ""
                }
            }
            .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
            Text(verbatim: "路由器取自代理后端的 SSH 设置；WG peer 从路由器的 WireGuard 配置自动发现。")
                .font(WgInk.mono(9.5)).foregroundStyle(WgInk.ink3)
        }
        .disabled(lab.running)
    }
}
