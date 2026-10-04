import AppKit
import Combine
import QuartzCore
import SwiftUI

/// V-sync for this HUD only. Work is bounded by an event deadline, not a perpetual timer.
@MainActor
final class WgHUDDisplayClock: NSObject, ObservableObject {
    @Published private(set) var now = Date()
    private var deadline = Date.distantPast
    private var link: CADisplayLink?

    func attach(to view: NSView) {
        link?.invalidate()
        guard view.window != nil else { link = nil; return }
        let next = view.displayLink(target: self, selector: #selector(tick(_:)))
        let maximum = Float(min(120, view.window?.screen?.maximumFramesPerSecond ?? 60))
        // Active motion uses the display's full refresh rate; idle work is paused below.
        next.preferredFrameRateRange = CAFrameRateRange(minimum: maximum, maximum: maximum, preferred: maximum)
        next.isPaused = Date() >= deadline
        next.add(to: .main, forMode: .common)
        link = next
    }

    func play(for duration: TimeInterval = WgHUDMotion.duration) {
        let instant = Date()
        let wasIdle = link?.isPaused != false
        deadline = max(deadline, instant.addingTimeInterval(duration))
        if wasIdle { now = instant }
        link?.isPaused = false
    }

    func stop() { deadline = .distantPast; link?.isPaused = true }
    func detach() { link?.invalidate(); link = nil }

    @objc private func tick(_ sender: CADisplayLink) {
        now = Date()
        if now >= deadline { sender.isPaused = true }
    }
}

struct WgHUDClockBridge: NSViewRepresentable {
    var clock: WgHUDDisplayClock
    func makeNSView(context: Context) -> ClockView { ClockView(clock: clock) }
    func updateNSView(_ nsView: ClockView, context: Context) {}
    static func dismantleNSView(_ nsView: ClockView, coordinator: ()) { nsView.clock.detach() }

    final class ClockView: NSView {
        let clock: WgHUDDisplayClock
        init(clock: WgHUDDisplayClock) { self.clock = clock; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); clock.attach(to: self) }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
