import SwiftUI

// 读数格式（测速台各处共用）。

enum SLFormat {
    /// 读数固定 4 个字符：0502 · 62.7 · 9.87，等待时 ————。
    static func reading(_ mbps: Double?, unit: SLUnit) -> String {
        guard let mbps else { return "————" }
        let v = unit.value(mbps)
        if v >= 1000 { return String(format: "%.0f", v) }
        if v >= 100 { return String(format: "%04.0f", v) }
        if v >= 10 { return String(format: "%04.1f", v) }
        return String(format: "%.2f", max(0, v))
    }

    static func compact(_ mbps: Double?, unit: SLUnit) -> String {
        guard let mbps else { return "—" }
        let v = unit.value(mbps)
        return v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v)
    }

    static func rtt(_ ms: Double?) -> String {
        guard let ms else { return "—" }
        return ms >= 100 ? String(format: "%.0f ms", ms) : String(format: "%.1f ms", ms)
    }

    static func tick(_ v: Double) -> String {
        if v == 0 { return "0" }
        if v >= 1000, v.truncatingRemainder(dividingBy: 1000) == 0 { return "\(Int(v / 1000))G" }
        if v >= 1 { return String(format: "%.0f", v) }
        return String(format: "%.1f", v)
    }
}
