import Combine
import Foundation

enum WgLinkPhase: Equatable {
    case offline, home, idle, connecting, linked
}

/// These are observations, not a reachability test or proof that a peer received traffic.
enum WgLinkAlarm: Equatable {
    case transmitStall, unstable
}

struct WgLinkSample: Equatable {
    var at: Date
    /// Per-observation interval rates; the snapshot readouts separately use a 30-second average.
    var rxLevel: Int
    var txLevel: Int
    var rxRate: Double
    var txRate: Double
    var available: Bool
}

/// A bounded, read-only picture of daemon observations for the HUD renderer.
struct WgLinkSnapshot: Equatable {
    var handshakeEvent: Date?
    var rebindEvent: Date?
    /// Retained for existing renderers; only a suspected transmit stall sets this date.
    var stalled: Date?
    var alarm: WgLinkAlarm?
    var alarmEvent: Date?
    var activityEvent: Date?
    var recoveryEvent: Date?
    var linkEvent: Date?
    var dataEvent: Date?
    var rxLevel = 0
    var txLevel = 0
    var rxRate: Double = 0
    var txRate: Double = 0
    /// 6 = fresh handshake; 0 = unknown or at least 180 seconds old.
    var freshness = 0
    var handshakeAge: Int?
    var rebindsLastHour = 0
    /// Two consecutive valid samples are required before presenting a measured rate.
    var trafficAvailable = false
    var lastDataAt: Date?
    var history: [WgLinkSample] = []
}

/// Only consumes status fields. It never invokes a daemon command or changes a tunnel.
@MainActor
final class WgLinkMonitor: ObservableObject {
    nonisolated static let fps: Double = 24
    nonisolated static let blink: [Double] = [0, 0.35, 0.68, 1]
    nonisolated static let settle: [Double] = [1, 0.3, 0]
    nonisolated static let precursorFrames = 2
    nonisolated static let levels = 8
    nonisolated static let animationDuration: TimeInterval = 16 / fps
    nonisolated static let stallWindow: TimeInterval = 35
    nonisolated static let rateWindow: TimeInterval = 30
    /// Status normally arrives every 2 seconds. Missing three polls invalidates the display.
    nonisolated static let dataStaleWindow: TimeInterval = 6
    nonisolated static let maxHistorySamples = 61

    @Published private(set) var snapshot = WgLinkSnapshot()

    private struct Counters {
        var at: Date
        var tx: UInt64
        var rx: UInt64
    }
    private struct RebindBatch {
        var at: Date
        var count: Int
    }

    private var lastHandshake: String?
    private var lastRebinds: Int?
    private var lastRebindObservationAt: Date?
    private let handshakeFormatter = ISO8601DateFormatter()
    private var rebindBatches: [RebindBatch] = []
    private var samples: [Counters] = []
    private var txAdvancedAt: Date?
    private var rxAdvancedAt: Date?
    private var lastObservationAt: Date?
    private var lastTunnelUp: Bool?
    private var wakeUp: DispatchWorkItem?
    private var staleWakeUp: DispatchWorkItem?

    func ingest(handshake: String?, handshakeAge: Int?, tx: UInt64?, rx: UInt64?, rebinds: Int?,
                tunnelUp: Bool, at now: Date = Date()) {
        // An older response must not rewind counters or bring expired data back to life.
        if let lastObservationAt, now < lastObservationAt { return }
        lastObservationAt = now
        scheduleDataExpiry(observedAt: now)
        var next = snapshot
        let wasAvailable = next.trafficAvailable
        var intervalSample: WgLinkSample?

        rebindBatches.removeAll { now.timeIntervalSince($0.at) >= 3600 }
        if let rebinds, rebinds >= 0 {
            if let previous = lastRebinds, let observedAt = lastRebindObservationAt,
               now.timeIntervalSince(observedAt) <= Self.dataStaleWindow, rebinds > previous {
                // Keep the cumulative delta, not one marker per status response.
                rebindBatches.append(RebindBatch(at: now, count: rebinds - previous))
                next.rebindEvent = now
            }
            // A daemon restart is a new baseline; it does not erase observed hour history.
            lastRebinds = rebinds
            lastRebindObservationAt = now
        }
        next.rebindsLastHour = Self.saturatingTotal(rebindBatches.map(\.count))

        if let lastTunnelUp, lastTunnelUp != tunnelUp { next.linkEvent = now }
        lastTunnelUp = tunnelUp
        guard tunnelUp else {
            clearMeasurements(&next, clearHistory: true)
            next.handshakeEvent = nil
            next.activityEvent = nil
            next.recoveryEvent = nil
            next.dataEvent = nil
            publish(next)
            return
        }

        let key = handshake?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let key, !key.isEmpty {
            if let previous = lastHandshake, key != previous { next.handshakeEvent = now }
            lastHandshake = key
        } else {
            lastHandshake = nil
        }
        var age = handshakeAge.flatMap { $0 >= 0 ? $0 : nil }
        // The daemon omits a zero-valued age. Its absolute timestamp still proves freshness.
        if handshakeAge == nil, let key, let handshakeDate = handshakeFormatter.date(from: key) {
            let elapsed = now.timeIntervalSince(handshakeDate)
            if elapsed >= 0, elapsed < Double(Int.max / 2) { age = Int(elapsed) }
        }
        next.handshakeAge = age
        next.freshness = age.map { min(6, max(0, 6 - $0 / 30)) } ?? 0

        if let tx, let rx {
            let prior = samples.last
            let reset = prior.map { tx < $0.tx || rx < $0.rx } ?? false
            let gap = prior.map { now.timeIntervalSince($0.at) > Self.dataStaleWindow } ?? false
            if reset || gap {
                samples.removeAll()
                txAdvancedAt = nil
                rxAdvancedAt = nil
                next.history.removeAll()
            }
            if let last = samples.last {
                if tx > last.tx { txAdvancedAt = now }
                if rx > last.rx { rxAdvancedAt = now }
                let interval = now.timeIntervalSince(last.at)
                if interval > 0 {
                    let rxRate = Double(rx - last.rx) / interval
                    let txRate = Double(tx - last.tx) / interval
                    intervalSample = WgLinkSample(at: now, rxLevel: Self.level(rxRate), txLevel: Self.level(txRate),
                                                  rxRate: rxRate, txRate: txRate, available: true)
                }
            } else {
                txAdvancedAt = now
            }
            if samples.last?.at == now { samples.removeLast() }
            samples.append(Counters(at: now, tx: tx, rx: rx))
            // Keep one baseline at/before the cutoff for an interpolated 30-second average.
            let cutoff = now.addingTimeInterval(-Self.rateWindow)
            while samples.count > 2 && samples[1].at <= cutoff { samples.removeFirst() }
            if samples.count > Self.maxHistorySamples { samples.removeFirst(samples.count - Self.maxHistorySamples) }

            next.rxRate = 0
            next.txRate = 0
            next.trafficAvailable = false
            if let first = samples.first, let last = samples.last, last.at > first.at {
                let totalDuration = last.at.timeIntervalSince(first.at)
                var received = Double(last.rx - first.rx)
                var sent = Double(last.tx - first.tx)
                if first.at < cutoff, samples.count > 1 {
                    let second = samples[1]
                    let fraction = cutoff.timeIntervalSince(first.at) / second.at.timeIntervalSince(first.at)
                    received -= Double(second.rx - first.rx) * fraction
                    sent -= Double(second.tx - first.tx) * fraction
                }
                let duration = min(Self.rateWindow, totalDuration)
                next.rxRate = max(0, received / duration)
                next.txRate = max(0, sent / duration)
                next.trafficAvailable = true
            }
            next.lastDataAt = now
            next.rxLevel = Self.level(next.rxRate)
            next.txLevel = Self.level(next.txRate)
        } else {
            samples.removeAll()
            txAdvancedAt = nil
            rxAdvancedAt = nil
            next.rxRate = 0
            next.txRate = 0
            next.rxLevel = 0
            next.txLevel = 0
            next.trafficAvailable = false
            next.lastDataAt = nil
        }

        if wasAvailable != next.trafficAvailable {
            next.dataEvent = now
        }
        if next.trafficAvailable && (next.rxLevel != snapshot.rxLevel || next.txLevel != snapshot.txLevel) {
            // A rate changing within one band does not continuously retrigger the sweep.
            next.activityEvent = now
        }

        let silentSend = txAdvancedAt.map { now.timeIntervalSince($0) > Self.stallWindow } ?? false
        let receivingNow = rxAdvancedAt.map { now.timeIntervalSince($0) < Self.dataStaleWindow } ?? false
        let stalled = next.trafficAvailable && silentSend && receivingNow
        let rebindsInMinute = Self.saturatingTotal(rebindBatches.filter { now.timeIntervalSince($0.at) < 60 }.map(\.count))
        let unstable = rebindsInMinute >= 3
        let alarm: WgLinkAlarm? = stalled ? .transmitStall : (unstable ? .unstable : nil)
        if stalled {
            if next.stalled == nil { next.stalled = now }
        } else {
            next.stalled = nil
        }
        if alarm != snapshot.alarm {
            next.alarmEvent = alarm == nil ? nil : now
            if alarm == nil, snapshot.alarm != nil, next.trafficAvailable { next.recoveryEvent = now }
        }
        next.alarm = alarm
        appendHistory(to: &next, at: now, sample: intervalSample)
        publish(next)
    }

    /// Call on a failed status fetch. A short timeout also invokes this if polling stops.
    func markUnavailable(at now: Date = Date()) {
        if let lastObservationAt, now < lastObservationAt { return }
        lastObservationAt = now
        staleWakeUp?.cancel()
        // We cannot locate rebinding events inside an unobserved gap. Rebaseline on return.
        lastRebinds = nil
        lastRebindObservationAt = nil
        var next = snapshot
        let hadData = next.lastDataAt != nil || next.handshakeAge != nil || next.alarm != nil
        clearMeasurements(&next, clearHistory: false)
        next.handshakeEvent = nil
        next.rebindEvent = nil
        next.activityEvent = nil
        next.recoveryEvent = nil
        next.linkEvent = nil
        if hadData { next.dataEvent = now }
        appendHistory(to: &next, at: now)
        rebindBatches.removeAll { now.timeIntervalSince($0.at) >= 3600 }
        next.rebindsLastHour = Self.saturatingTotal(rebindBatches.map(\.count))
        publish(next)
    }

    private func clearMeasurements(_ next: inout WgLinkSnapshot, clearHistory: Bool) {
        lastHandshake = nil
        samples.removeAll()
        txAdvancedAt = nil
        rxAdvancedAt = nil
        next.alarm = nil
        next.alarmEvent = nil
        next.stalled = nil
        next.rxRate = 0
        next.txRate = 0
        next.rxLevel = 0
        next.txLevel = 0
        next.freshness = 0
        next.handshakeAge = nil
        next.trafficAvailable = false
        next.lastDataAt = nil
        if clearHistory { next.history.removeAll() }
    }

    private func appendHistory(to next: inout WgLinkSnapshot, at now: Date, sample: WgLinkSample? = nil) {
        next.history.removeAll { now.timeIntervalSince($0.at) > Self.rateWindow }
        if next.history.last?.at == now { next.history.removeLast() }
        // A missing/reset baseline is a gap, never a synthetic zero-speed observation.
        next.history.append(sample ?? WgLinkSample(at: now, rxLevel: 0, txLevel: 0, rxRate: 0, txRate: 0, available: false))
        if next.history.count > Self.maxHistorySamples { next.history.removeFirst(next.history.count - Self.maxHistorySamples) }
    }

    /// 100 B/s or less is band zero; 10 MB/s reaches the eighth band.
    nonisolated static func level(_ rate: Double) -> Int {
        guard rate.isFinite else { return rate == .infinity ? levels : 0 }
        guard rate > 100 else { return 0 }
        let x = (log10(rate) - 2) / 5
        return min(levels, max(1, Int((x * Double(levels)).rounded(.up))))
    }

    private static func saturatingTotal(_ values: [Int]) -> Int {
        values.reduce(0) { total, value in
            let (sum, overflow) = total.addingReportingOverflow(value)
            return overflow ? Int.max : sum
        }
    }

    private var eventDates: [Date?] {
        [snapshot.handshakeEvent, snapshot.rebindEvent, snapshot.alarmEvent,
         snapshot.activityEvent, snapshot.recoveryEvent, snapshot.linkEvent, snapshot.dataEvent]
    }

    private func publish(_ next: WgLinkSnapshot) {
        guard next != snapshot else { return }
        let previousEvents = eventDates
        snapshot = next
        if eventDates != previousEvents {
            wakeUp?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.objectWillChange.send() }
            wakeUp = work
            // A final observation makes TimelineView reevaluate its paused condition.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.animationDuration + 1 / Self.fps, execute: work)
        }
    }

    private func scheduleDataExpiry(observedAt now: Date) {
        staleWakeUp?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.lastObservationAt == now else { return }
            self.markUnavailable(at: now.addingTimeInterval(Self.dataStaleWindow))
        }
        staleWakeUp = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.dataStaleWindow, execute: work)
    }

    nonisolated static func frame(since event: Date?, at now: Date) -> Int? {
        guard let event else { return nil }
        let dt = now.timeIntervalSince(event)
        guard dt >= 0, dt.isFinite else { return nil }
        // Old events remain useful as observations without risking an overflowing conversion.
        return Int(min(floor(dt * fps), Double(Int.max / 2)))
    }

    func isAnimating(at now: Date) -> Bool {
        eventDates.contains { event in
            guard let event else { return false }
            let dt = now.timeIntervalSince(event)
            return dt >= 0 && dt < Self.animationDuration
        }
    }
}
