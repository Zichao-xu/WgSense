import Foundation

@main
struct MotionRegression {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else { fatalError("FAIL: \(message)") }
            checks += 1
        }
        func close(_ a: Double, _ b: Double, tolerance: Double = 1e-10) -> Bool {
            abs(a - b) <= tolerance
        }
        let samples = (0...10_000).map { Double($0) / 10_000 }
        let duration = WgHUDMotion.duration
        let origin = Date(timeIntervalSinceReferenceDate: 100)

        check(WgHUDMotion.fps == 120 && duration == 1.25, "motion requests the 120 Hz cadence and bounded lifetime")
        check(WgHUDMotion.progress(time: 10, since: nil) == 1, "missing entrance is already settled")
        check(WgHUDMotion.progress(time: 9, since: 10) == 0, "future events cannot advance motion")
        check(WgHUDMotion.progress(time: 10, since: 10) == 0, "event starts at zero")
        check(WgHUDMotion.progress(time: 10 + duration, since: 10) == 1, "event reaches its exact endpoint")
        check(WgHUDMotion.progress(time: 999, since: 10) == 1, "late frames stay settled")
        check(WgHUDMotion.progress(time: 10.2, since: 10, delay: 0.3) == 0, "delayed layers cannot appear early")
        check(close(WgHUDMotion.progress(time: 10.925, since: 10, delay: 0.3), 0.5), "delay does not shorten a layer's duration")
        check(WgHUDMotion.progress(time: 10, since: 10, duration: 0) == 1, "zero-duration motion settles immediately")
        check(WgHUDMotion.progress(time: 9, since: 10, duration: 0) == 0, "zero-duration motion still respects event time")
        check(WgHUDMotion.progress(time: .nan, since: 10) == 0
              && WgHUDMotion.progress(time: 10, since: .infinity) == 0, "invalid timestamps cannot poison drawing coordinates")
        check(close(WgHUDMotion.progress(time: origin.addingTimeInterval(0.625), since: origin), 0.5), "Date and numeric clocks use the same elapsed-time model")

        for (name, curve) in [("quint", WgHUDMotion.easeOutQuint),
                              ("smoothstep", WgHUDMotion.smoothstep),
                              ("spring", WgHUDMotion.spring)] {
            check(curve(0) == 0 && curve(1) == 1, "\(name) has exact endpoints")
            check(curve(-1) == 0 && curve(2) == 1, "\(name) safely clamps outside its duration")
            check(curve(.nan).isFinite && curve(.infinity).isFinite,
                  "\(name) never produces a non-finite drawing value")
        }
        for (name, curve) in [("quint", WgHUDMotion.easeOutQuint),
                              ("smoothstep", WgHUDMotion.smoothstep)] {
            let values = samples.map(curve)
            check(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 }, "\(name) never reverses a reveal")
            check(values.allSatisfy { (0...1).contains($0) }, "\(name) remains safe for opacity")
        }
        let spring = samples.map(WgHUDMotion.spring)
        check(spring.allSatisfy { (0...1.06).contains($0) }, "spring overshoot stays below six percent")
        check((spring.max() ?? 0) > 1.04, "spring has a visible but restrained recoil")
        let h = 1e-5
        check(abs((WgHUDMotion.spring(1) - WgHUDMotion.spring(1 - h)) / h) < 1e-4,
              "spring settles with zero end velocity before clock suspension")
        check(abs((WgHUDMotion.spring(h) - WgHUDMotion.spring(0)) / h) < 0.002,
              "spring starts with zero velocity")
        check(WgHUDMotion.pulse(0) == 0 && WgHUDMotion.pulse(1) == 0
              && WgHUDMotion.pulse(0.5) == 1, "pulse appears and vanishes cleanly")
        check(samples.map(WgHUDMotion.pulse).allSatisfy { (0...1).contains($0) }, "pulse is bounded for opacity")

        // 60 Hz and 120 Hz agree at every shared instant. Intermediate 120 Hz
        // samples genuinely differ; merely calling the old 24 fps clock more
        // often would fail the second assertion.
        let commonInstants = (0...75).map { Double($0) / 60 }
        check(commonInstants.allSatisfy { seconds in
            let at60 = WgHUDMotion.spring(WgHUDMotion.progress(time: seconds, since: 0))
            let at120 = WgHUDMotion.spring(WgHUDMotion.progress(time: seconds * 120 / 120, since: 0))
            return close(at60, at120)
        }, "frame rate changes never change motion position at a shared timestamp")
        let highRefresh = (0...24).map { frame in
            WgHUDMotion.spring(WgHUDMotion.progress(time: Double(frame) / 120, since: 0))
        }
        check(zip(highRefresh, highRefresh.dropFirst()).allSatisfy { $0 < $1 },
              "every 120 Hz attack sample advances instead of repeating 24 fps steps")
        let interrupted = WgHUDMotion.spring(WgHUDMotion.progress(time: duration, since: 0))
        check(interrupted == 1, "a skipped-frame interval lands at the same final state")
        print("HUD motion regression: \(checks) checks passed")
    }
}
