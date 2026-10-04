import Foundation

/// Continuous HUD motion. Every value is derived from elapsed wall time, never
/// frame count, so missed frames and 60 / 120 Hz displays share the same rhythm.
enum WgHUDMotion {
    static let fps = 120.0
    static let duration = 1.25

    /// A missing event is already settled. Use an explicit event check when an
    /// effect should be absent until the first event arrives.
    static func progress(time: Date, since event: Date?, duration: Double = duration,
                         delay: Double = 0) -> Double {
        progress(time: time.timeIntervalSinceReferenceDate,
                 since: event?.timeIntervalSinceReferenceDate,
                 duration: duration, delay: delay)
    }

    static func progress(time: Double, since event: Double?, duration: Double = duration,
                         delay: Double = 0) -> Double {
        guard let event else { return 1 }
        guard time.isFinite, event.isFinite, duration.isFinite, delay.isFinite else { return 0 }
        let elapsed = time - event - delay
        guard elapsed >= 0 else { return 0 }
        guard duration > 0 else { return 1 }
        return unit(elapsed / duration)
    }

    /// Fast attack with a long, soft arrival. For reveals and scan position.
    static func easeOutQuint(_ progress: Double) -> Double {
        let inverse = 1 - unit(progress)
        return 1 - inverse * inverse * inverse * inverse * inverse
    }

    /// Zero velocity at either end, without overshoot. For opacity and mixing.
    static func smoothstep(_ progress: Double) -> Double {
        let p = unit(progress)
        return p * p * (3 - 2 * p)
    }

    /// Underdamped step response with less than 6% overshoot. A short quintic
    /// tail settles both position and velocity exactly, allowing the view's
    /// display clock to pause without a final-frame snap.
    static func spring(_ progress: Double) -> Double {
        let p = unit(progress)
        guard p > 0 else { return 0 }
        guard p < 1 else { return 1 }
        let damping = 0.67
        let frequency = 12.0
        let oscillation = frequency * sqrt(1 - damping * damping)
        let response = 1 - exp(-damping * frequency * p)
            * (cos(oscillation * p) + damping * frequency / oscillation * sin(oscillation * p))
        let tail = unit((p - 0.82) / 0.18)
        let settle = tail * tail * tail * (tail * (tail * 6 - 15) + 10)
        return response + (1 - response) * settle
    }

    /// A single organic emphasis, with no discontinuity at appearance or exit.
    static func pulse(_ progress: Double) -> Double {
        let p = unit(progress)
        let envelope = p * (1 - p)
        return 16 * envelope * envelope
    }

    private static func unit(_ value: Double) -> Double {
        guard !value.isNaN else { return 0 }
        return min(1, max(0, value))
    }
}
