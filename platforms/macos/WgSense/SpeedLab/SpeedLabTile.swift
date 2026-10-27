import SwiftUI

// 侧栏「测速」磁贴：入口 + 一眼看结果。
//
//   小：标题 + 上次（或进行中）读数
//   中：右侧两块迷你表盘
//   大：迷你表盘 + 场景按钮，不进页面直接开测
// 平时是静态画面；只有测速进行中才随读数更新。

struct SLSpeedTile: View {
    var size: TileSize
    var isSelected: Bool
    var isEditMode: Bool
    var open: () -> Void
    @ObservedObject private var lab = SpeedLabStore.shared

    var body: some View {
        let last = lab.lastResult
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(TileKind.speedtest.title).font(.system(size: 15, weight: .bold)).lineLimit(1)
                    Text(verbatim: status(last))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(lab.error != nil && !lab.running ? WgInk.alert : WgInk.ink3)
                        .lineLimit(1)
                }
                if size == .medium {
                    Spacer(minLength: 4)
                    gauges(last).frame(height: 60)
                }
            }
            if size == .large {
                gauges(last).frame(height: 74).frame(maxWidth: .infinity)
                Spacer(minLength: 0)
                sceneButtons
            }
        }
        .padding(.leading, 14).padding(.trailing, 12).padding(.vertical, size == .small ? 13 : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: size == .large ? .topLeading : .leading)
        .overlay(alignment: .topLeading) {
            Rectangle().fill(WgInk.ink.opacity(lab.running ? 0.9 : 0.45)).frame(width: 3, height: 20)
        }
        .overlay(alignment: .topTrailing) {
            Text(verbatim: TileKind.speedtest.code).font(WgInk.mono(9.5)).tracking(1).foregroundStyle(WgInk.ink4).padding(9)
        }
        .wgInteractiveSurface(isSelected: isSelected, isEnabled: !isEditMode, action: open)
    }

    private func status(_ last: SLResult?) -> String {
        let unit = lab.params.unit
        if lab.running {
            if let v = lab.upNow ?? lab.downNow {
                return "\(lab.phase.title) \(SLFormat.compact(v, unit: unit)) \(unit.title)"
            }
            return lab.note
        }
        guard let last else { return "未测" }
        if let error = last.error { return error }
        // 小磁贴没有表盘：读数写在状态行；中、大磁贴读数在表盘上，状态行只写时间。
        if size == .small {
            return "↓\(SLFormat.compact(last.down?.stable, unit: unit)) ↑\(SLFormat.compact(last.up?.stable, unit: unit))"
        }
        return "上次 " + last.date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow))
    }

    /// 两条通道的缩略：长度 = 吞吐 / 协商速率（和 HUD 两翼同一含义），右侧读数。
    private func gauges(_ last: SLResult?) -> some View {
        let scale = Double(lab.running ? (lab.linkMbps ?? 1000) : (last?.linkMbps ?? 1000))
        return VStack(alignment: .leading, spacing: 6) {
            channel("↓", lab.running ? lab.downNow : last?.down?.stable, scale)
            channel("↑", lab.running ? lab.upNow : last?.up?.stable, scale)
        }
        .frame(width: 128)
    }

    private func channel(_ arrow: String, _ value: Double?, _ scale: Double) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: arrow).font(WgInk.mono(10, .bold)).foregroundStyle(WgInk.ink3)
            GeometryReader { geo in
                let f = CGFloat(min(1, (value ?? 0) / max(scale, 1)))
                ZStack(alignment: .leading) {
                    ChamferShape(tr: 4).fill(WgInk.field)
                    ChamferShape(tr: 4).fill(WgInk.ink).frame(width: geo.size.width * f)
                }
            }
            .frame(height: 8)
            Text(verbatim: SLFormat.compact(value, unit: lab.params.unit))
                .font(WgInk.mono(10.5, .medium)).foregroundStyle(value == nil ? WgInk.ink4 : WgInk.ink)
                .frame(width: 34, alignment: .trailing)
        }
    }

    private var sceneButtons: some View {
        HStack(spacing: 6) {
            if lab.running {
                Button { lab.stop() } label: { Label("停止", systemImage: "stop.fill") }
                    .buttonStyle(SLChipStyle(selected: true))
            } else {
                ForEach(lab.scenes.prefix(3)) { scene in
                    Button(scene.title) {
                        lab.apply(scene)
                        lab.start()
                    }
                    .buttonStyle(SLChipStyle(selected: false))
                    .help("开测：\(scene.title)")
                }
            }
            Spacer(minLength: 0)
        }
        .disabled(isEditMode)
    }
}
