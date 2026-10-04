import Foundation

@main
struct MonitorRegression {
    @MainActor static func main() async throws {
        let origin = Date(timeIntervalSince1970: 2_000_000_000)
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAIL: \(message)") }
            checks += 1
        }
        func close(_ actual: Double, _ expected: Double) -> Bool { abs(actual - expected) < 0.001 }
        func time(_ offset: Double) -> Date { origin.addingTimeInterval(offset) }
        func feed(_ monitor: WgLinkMonitor, _ offset: Double, tx: UInt64? = 0, rx: UInt64? = 0,
                  rebinds: Int? = 0, age: Int? = 4, handshake: String? = "first", up: Bool = true) {
            monitor.ingest(handshake: handshake, handshakeAge: age, tx: tx, rx: rx,
                           rebinds: rebinds, tunnelUp: up, at: time(offset))
        }

        // Unknown data is different from an observed, quiet connection.
        let basic = WgLinkMonitor()
        check(!basic.snapshot.trafficAvailable, "new monitor starts with unknown traffic")
        feed(basic, 0)
        check(!basic.snapshot.trafficAvailable, "one counter sample is not a rate")
        feed(basic, 2, tx: 200, rx: 2_000)
        check(basic.snapshot.trafficAvailable, "second sample establishes measured rate")
        check(close(basic.snapshot.txRate, 100) && close(basic.snapshot.rxRate, 1_000), "rates use elapsed time")
        check(basic.snapshot.rxLevel == 2 && basic.snapshot.txLevel == 0, "traffic uses logarithmic bands")
        let firstActivity = basic.snapshot.activityEvent
        feed(basic, 4, tx: 400, rx: 4_400)
        check(basic.snapshot.activityEvent == firstActivity, "same-band rate change does not retrigger animation")
        check(!basic.isAnimating(at: time(4)), "same-band update leaves clock paused")
        feed(basic, 6, tx: 600, rx: 30_000, handshake: "second")
        check(basic.snapshot.handshakeEvent == time(6) && basic.snapshot.activityEvent == time(6), "handshake and band changes have real event dates")
        check(basic.isAnimating(at: time(6.6)) && !basic.isAnimating(at: time(6.7)), "all animations stop after sixteen frames")
        check(WgLinkMonitor.frame(since: time(6), at: time(6.2)) == 4, "clock quantizes to 24 fps")
        check(WgLinkMonitor.frame(since: time(6), at: time(5)) == nil, "future events do not animate")

        feed(basic, 8, tx: 800, rx: 32_000, age: -3)
        check(basic.snapshot.handshakeAge == nil && basic.snapshot.freshness == 0, "negative age stays unknown")
        feed(basic, 10, tx: 1_000, rx: 34_000, age: 0)
        check(basic.snapshot.freshness == 6, "freshness upper bound is six")
        feed(basic, 12, tx: 1_200, rx: 36_000, age: Int.max)
        check(basic.snapshot.freshness == 0, "extreme handshake age stays in bounds")
        feed(basic, 14, tx: 1_400, rx: 38_000, age: nil, handshake: nil)
        check(basic.snapshot.handshakeAge == nil && basic.snapshot.freshness == 0, "missing handshake does not retain a stale freshness readout")
        let omittedAge = WgLinkMonitor()
        feed(omittedAge, 0, age: nil, handshake: ISO8601DateFormatter().string(from: time(0)))
        check(omittedAge.snapshot.freshness == 6 && omittedAge.snapshot.handshakeAge == 0, "omitted zero handshake age uses the absolute daemon timestamp")

        // Counter reset and large legitimate counters must never wrap into a huge speed.
        feed(basic, 16, tx: 2, rx: 4)
        check(basic.snapshot.rxRate == 0 && basic.snapshot.txRate == 0 && !basic.snapshot.trafficAvailable, "counter reset establishes a fresh baseline")
        check(basic.snapshot.history.last?.available == false, "reset is an explicit trace gap, not zero traffic")
        feed(basic, 18, tx: 102, rx: 204)
        check(close(basic.snapshot.rxRate, 100) && basic.snapshot.trafficAvailable, "measurement resumes after reset")
        let huge = WgLinkMonitor()
        feed(huge, 0, tx: UInt64.max - 200, rx: UInt64.max - 400)
        feed(huge, 2, tx: UInt64.max - 100, rx: UInt64.max - 200)
        check(close(huge.snapshot.txRate, 50) && close(huge.snapshot.rxRate, 100), "large counters subtract before Double conversion")
        feed(huge, 4, tx: 0, rx: 0)
        check(!huge.snapshot.trafficAvailable && huge.snapshot.rxLevel == 0, "counter wrap is treated as a reset")

        // Missing one field, failed polls and gaps invalidate an entire counter pair.
        feed(basic, 20, tx: nil, rx: 500)
        check(!basic.snapshot.trafficAvailable && basic.snapshot.lastDataAt == nil, "partial traffic fields are unavailable")
        feed(basic, 22, tx: 300, rx: 600)
        check(!basic.snapshot.trafficAvailable, "recovered field starts new baseline")
        feed(basic, 24, tx: 400, rx: 800)
        check(basic.snapshot.trafficAvailable, "complete pair resumes measured traffic")
        basic.markUnavailable(at: time(25))
        check(!basic.snapshot.trafficAvailable && basic.snapshot.handshakeAge == nil && basic.snapshot.alarm == nil, "failed fetch clears stale measurements and alarms")
        check(basic.snapshot.history.last?.available == false, "history includes an explicit unavailable gap")
        feed(basic, 24, tx: 500, rx: 1_000)
        check(!basic.snapshot.trafficAvailable, "older successful response cannot resurrect failed data")
        feed(basic, 26, tx: 500, rx: 1_000)
        feed(basic, 28, tx: 600, rx: 1_200)
        check(basic.snapshot.trafficAvailable && basic.snapshot.dataEvent == time(28), "data recovery emits one availability event")
        feed(basic, 36, tx: 1_000, rx: 2_000)
        check(!basic.snapshot.trafficAvailable, "long observation gap cannot masquerade as a current speed")
        check(basic.snapshot.history.last?.available == false, "long observation gap is also missing in the traffic trace")
        feed(basic, 38, tx: 1_100, rx: 2_200)
        feed(basic, 40, tx: 1_200, rx: 2_400, up: false)
        check(basic.snapshot.history.isEmpty && !basic.snapshot.trafficAvailable && basic.snapshot.alarm == nil, "down phase clears measurements, history and alarms")
        check(basic.snapshot.linkEvent == time(40), "tunnel state transition has an event date")

        // Recent receive activity is required; stale receive history alone is not a TX alarm.
        let quiet = WgLinkMonitor()
        feed(quiet, 0)
        for second in stride(from: 2, through: 40, by: 2) { feed(quiet, Double(second), rx: 500) }
        check(quiet.snapshot.alarm == nil, "fully idle connection is not a suspected transmit stall")
        let stall = WgLinkMonitor()
        feed(stall, 0)
        for second in stride(from: 2, through: 36, by: 2) { feed(stall, Double(second), rx: UInt64(second * 500)) }
        check(stall.snapshot.alarm == .transmitStall && stall.snapshot.stalled == time(36), "recent RX with TX silent for 35 seconds produces a suspected stall")
        feed(stall, 38, tx: 100, rx: 20_000)
        check(stall.snapshot.alarm == nil && stall.snapshot.stalled == nil && stall.snapshot.recoveryEvent == time(38), "TX growth clears transmit alarm and emits recovery")

        // Instability is its own observation and survives a normal transmit increment.
        let rebind = WgLinkMonitor()
        feed(rebind, 0, rebinds: 10)
        feed(rebind, 2, tx: 100, rx: 100, rebinds: 13)
        check(rebind.snapshot.rebindsLastHour == 3, "three rebinds within a single poll are all counted")
        check(rebind.snapshot.alarm == .unstable && rebind.snapshot.stalled == nil, "rebind burst is not mislabeled as failed transmit")
        feed(rebind, 4, tx: 200, rx: 200, rebinds: 13)
        check(rebind.snapshot.alarm == .unstable, "TX progress does not clear an instability alarm")
        feed(rebind, 6, tx: 300, rx: 300, rebinds: nil)
        feed(rebind, 8, tx: 400, rx: 400, rebinds: 14)
        check(rebind.snapshot.rebindsLastHour == 4, "missing rebind field preserves the next cumulative delta")
        for second in stride(from: 10, through: 68, by: 2) {
            feed(rebind, Double(second), tx: UInt64(second * 50), rx: UInt64(second * 50), rebinds: 14)
        }
        check(rebind.snapshot.alarm == nil && rebind.snapshot.rebindsLastHour == 4, "minute alarm expires independently of hour count")
        feed(rebind, 70, tx: 3_500, rx: 3_500, rebinds: 0)
        feed(rebind, 72, tx: 3_600, rx: 3_600, rebinds: 2)
        check(rebind.snapshot.rebindsLastHour == 6, "daemon counter reset preserves observed hour history")
        feed(rebind, 3_602, rebinds: 2)
        check(rebind.snapshot.rebindsLastHour == 3, "hour boundary expires full count of an old batch")
        feed(rebind, 3_672, rebinds: 2)
        check(rebind.snapshot.rebindsLastHour == 0, "hour history fully expires")
        let unobserved = WgLinkMonitor()
        feed(unobserved, 0, rebinds: 0)
        unobserved.markUnavailable(at: time(1))
        feed(unobserved, 300, rebinds: 3)
        check(unobserved.snapshot.alarm == nil && unobserved.snapshot.rebindsLastHour == 0, "unobserved rebinds during a failed-fetch gap are not presented as a current burst")
        feed(unobserved, 302, rebinds: 4)
        check(unobserved.snapshot.rebindsLastHour == 1, "new rebinding is counted after observation resumes")
        feed(unobserved, 600, rebinds: 7)
        check(unobserved.snapshot.alarm == nil && unobserved.snapshot.rebindsLastHour == 1, "long polling pause also rebaselines rebinds without a false instability alarm")

        let alarmPriority = WgLinkMonitor()
        feed(alarmPriority, 0)
        for second in stride(from: 2, through: 36, by: 2) {
            feed(alarmPriority, Double(second), rx: UInt64(second * 500), rebinds: second == 36 ? 3 : 0)
        }
        check(alarmPriority.snapshot.alarm == .transmitStall, "transmit observation takes priority over concurrent rebinding")
        feed(alarmPriority, 38, tx: 100, rx: 20_000, rebinds: 3)
        check(alarmPriority.snapshot.alarm == .unstable && alarmPriority.snapshot.recoveryEvent == nil, "TX recovery reveals continuing instability without a false all-clear")

        let saturation = WgLinkMonitor()
        feed(saturation, 0)
        feed(saturation, 2, rebinds: Int.max)
        feed(saturation, 4, rebinds: 0)
        feed(saturation, 6, rebinds: Int.max)
        check(saturation.snapshot.rebindsLastHour == Int.max, "extreme cumulative rebind totals saturate safely")

        // Thirty-second history is bounded in both time and memory, including rapid polling.
        let rolling = WgLinkMonitor()
        for second in 0...100 { feed(rolling, Double(second), tx: UInt64(second * 1_000), rx: UInt64(second * 2_000)) }
        check(close(rolling.snapshot.txRate, 1_000) && close(rolling.snapshot.rxRate, 2_000), "rolling average remains exact for steady measured traffic")
        check(rolling.snapshot.history.first?.at == time(70) && rolling.snapshot.history.last?.at == time(100), "history contains only the last thirty seconds")
        check(rolling.snapshot.history.count <= WgLinkMonitor.maxHistorySamples, "history stays within the memory bound")
        let burst = WgLinkMonitor()
        feed(burst, 0)
        feed(burst, 2, tx: 2_000, rx: 2_000)
        feed(burst, 4, tx: 22_000, rx: 202_000)
        check(close(burst.snapshot.txRate, 5_500) && close(burst.snapshot.rxRate, 50_500), "main readouts retain the rolling average across a traffic burst")
        check(burst.snapshot.history.last?.rxRate == 100_000 && burst.snapshot.history.last?.txRate == 10_000,
              "history preserves actual adjacent-interval rates instead of smoothing the burst twice")
        check(burst.snapshot.history.last?.rxLevel == WgLinkMonitor.level(100_000), "trace bands use the interval rate")
        feed(burst, 6, tx: 22_000, rx: 202_000)
        check(burst.snapshot.history.last?.available == true && burst.snapshot.history.last?.rxRate == 0,
              "observed zero traffic remains a genuine zero trace sample")
        let irregular = WgLinkMonitor()
        for second in stride(from: 0, through: 35, by: 5) { feed(irregular, Double(second), tx: UInt64(second * 100), rx: UInt64(second * 200)) }
        feed(irregular, 38, tx: 3_800, rx: 7_600)
        check(close(irregular.snapshot.txRate, 100) && close(irregular.snapshot.rxRate, 200), "irregular polls interpolate the thirty-second boundary")
        let rapid = WgLinkMonitor()
        for tick in 0...400 { feed(rapid, Double(tick) / 10, tx: UInt64(tick * 10), rx: UInt64(tick * 20)) }
        check(rapid.snapshot.history.count == WgLinkMonitor.maxHistorySamples, "rapid poll history is capped")
        check(WgLinkMonitor.level(.nan) == 0 && WgLinkMonitor.level(.infinity) == 8 && WgLinkMonitor.level(-1) == 0, "invalid rate input cannot trap or exceed bands")

        // Exercise the real expiry callback, not just its explicit failure entrypoint.
        let expiring = WgLinkMonitor()
        let wallTime = Date()
        expiring.ingest(handshake: "recent", handshakeAge: 1, tx: 0, rx: 0, rebinds: 0, tunnelUp: true, at: wallTime.addingTimeInterval(-2))
        expiring.ingest(handshake: "recent", handshakeAge: 3, tx: 200, rx: 2_000, rebinds: 0, tunnelUp: true, at: wallTime)
        check(expiring.snapshot.trafficAvailable, "expiry fixture begins with current measured traffic")
        try await Task.sleep(for: .seconds(WgLinkMonitor.dataStaleWindow + 0.25))
        check(!expiring.snapshot.trafficAvailable && expiring.snapshot.handshakeAge == nil, "stopped polling automatically expires data after six seconds")
        print("PASS: \(checks) HUD monitor checks; model only, no app, daemon or network operations.")
    }
}
