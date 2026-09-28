import CoreGraphics
import Foundation
// swipe.swift <秒>：模拟触控板手势滚动（带 began/changed/ended 阶段），每 1.4s 一次反向手势。
let secs = Double(CommandLine.arguments.dropFirst().first ?? "10") ?? 10
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
guard let w = list.first(where: { ($0["kCGWindowOwnerName"] as? String) == "WgSense" && ($0["kCGWindowLayer"] as? Int) == 0 }),
      let b = w["kCGWindowBounds"] as? [String: CGFloat] else { print("no window"); exit(1) }
let pt = CGPoint(x: b["X"]! + b["Width"]! * 0.62, y: b["Y"]! + b["Height"]! * 0.6)
CGWarpMouseCursorPosition(pt)
func post(_ dy: Int32, phase: Int64) {
    let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: dy, wheel2: 0, wheel3: 0)!
    e.location = pt
    e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
    e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    e.post(tap: .cghidEventTap)
}
let start = Date()
var dir: Int32 = -1
while Date().timeIntervalSince(start) < secs {
    post(0, phase: 1)                       // began
    let g = Date()
    while Date().timeIntervalSince(g) < 1.4 {
        post(dir * 16, phase: 2)            // changed
        usleep(8_000)
    }
    post(0, phase: 4)                       // ended
    usleep(60_000)
    dir = -dir
}
