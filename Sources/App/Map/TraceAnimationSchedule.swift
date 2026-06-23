// TraceAnimationSchedule — a demand-driven `TimelineSchedule` for the Network map's
// animated trace overlay. The stock `TimelineView(.animation)` repaints at the full
// display refresh rate (60–120fps) CONTINUOUSLY and forever, pinning a CPU at 100%
// even when nothing is animating. This schedule instead emits frames ONLY while at
// least one packet trace is still drawing, caps the cadence at ~30fps, and then ENDS
// (finite sequence) so SwiftUI stops asking for frames and the view idles until it is
// re-created with a fresh horizon.
//
// All times are in the `Date().timeIntervalSinceReferenceDate` scale — the same clock
// `TraceRenderer.clock`/`PacketTrace.startedAt` use — so `horizon(for:…)` and the
// schedule's start dates are directly comparable.
//
// Following `TraceRenderer`, this imports SwiftUI unconditionally in the App module;
// no platform gates.

import Domain
import SwiftUI

/// A `TimelineSchedule` that only ticks while a packet trace is animating, at ~30fps,
/// then stops — so an idle map costs zero repaints. The "horizon" is the absolute time
/// (seconds since the reference date) at which the LAST pending trace finishes; once a
/// frame is drawn one interval past it, the sequence ends.
public struct TraceAnimationSchedule: TimelineSchedule {
    /// Default frame cadence: ~30fps. The animated overlay reads smoothly at this rate
    /// while costing roughly a quarter of an unbounded 120fps schedule.
    public static let defaultFrameInterval: Double = 1.0 / 30.0

    /// Sentinel returned by `horizon(for:…)` when there is nothing to animate (no
    /// pending traces). Any real start date compares as already-past this, so the
    /// schedule yields a single frame and stops.
    public static let nothingPending: Double = -.infinity

    /// Absolute time (seconds since the reference date) at which the last pending trace
    /// finishes drawing. `nothingPending` when there is nothing to animate.
    public let horizon: Double

    /// Seconds between emitted frames. Defaults to ~30fps.
    public let frameInterval: Double

    /// When true the schedule is "paused": it yields exactly one frame and stops,
    /// regardless of `horizon`. Used when the animation clock is driven EXTERNALLY
    /// (e.g. VCR replay scrubbing) so SwiftUI's wall clock must not advance it.
    public let isStatic: Bool

    public init(
        horizon: Double,
        frameInterval: Double = TraceAnimationSchedule.defaultFrameInterval,
        isStatic: Bool = false
    ) {
        self.horizon = horizon
        self.frameInterval = max(frameInterval, .leastNonzeroMagnitude)
        self.isStatic = isStatic
    }

    /// A static/paused schedule: a single frame, then stop. The clock is supplied by
    /// the caller (replay), so SwiftUI must not request a stream of frames.
    public static var paused: TraceAnimationSchedule {
        TraceAnimationSchedule(horizon: nothingPending, isStatic: true)
    }

    /// The absolute time at which the latest-finishing pending trace completes, in the
    /// `timeIntervalSinceReferenceDate` scale.
    ///
    /// = max over `traces` of
    ///   `startedAt + TraceTiming.journeyDuration(edgeCount: max(maxHopIndex, hops), …)`.
    ///
    /// `max(maxHopIndex, hops)` is used deliberately: an undecomposable multi-hop path
    /// may be drawn as a single hop-1 edge, so `maxHopIndex` can understate the true hop
    /// count — `hops` then carries the real depth. Returns `nothingPending` when there
    /// are no traces.
    public static func horizon(
        for traces: [PacketTrace],
        hopDuration: Double,
        mode: TraceTimingMode
    ) -> Double {
        var result = nothingPending
        for trace in traces {
            let edgeCount = max(trace.maxHopIndex, trace.hops)
            let finish = trace.startedAt + TraceTiming.journeyDuration(
                edgeCount: edgeCount,
                hopDuration: hopDuration,
                mode: mode
            )
            result = max(result, finish)
        }
        return result
    }

    /// The frames this schedule will emit, starting at `startDate`, spaced by
    /// `frameInterval`, continuing up to and ONE interval PAST `horizon` (so the
    /// completed final frame draws), then stopping. Pure and bounded — at most a few
    /// hundred dates for a multi-second animation at 30fps.
    ///
    /// Returns just `[startDate]` (one frame, then idle) when the schedule is static,
    /// or when `startDate` is already at/past the horizon (animation finished / nothing
    /// pending).
    public func frameDates(from startDate: Date) -> [Date] {
        let start = startDate.timeIntervalSinceReferenceDate

        // Static (externally-clocked) or nothing left to animate: one frame, then stop.
        if isStatic || !(start < horizon) {
            return [startDate]
        }

        // Draw up to and one interval past the horizon so the final, completed frame is
        // painted, then end. Cap the count defensively so a pathological horizon can
        // never produce an unbounded array.
        let span = horizon - start
        let steps = Int((span / frameInterval).rounded(.up)) + 1
        let boundedSteps = max(1, min(steps, TraceAnimationSchedule.maxFrames))

        var dates: [Date] = []
        dates.reserveCapacity(boundedSteps + 1)
        for step in 0 ... boundedSteps {
            dates.append(startDate.addingTimeInterval(Double(step) * frameInterval))
        }
        return dates
    }

    /// Hard ceiling on emitted frames, so an out-of-range horizon (or a tiny frame
    /// interval) can never allocate an unbounded array. 30fps × 600 frames = 20s of
    /// animation, comfortably above any real trace journey.
    static let maxFrames = 600

    public func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(dates: frameDates(from: startDate))
    }

    /// A finite, bounded sequence of frame dates. When it is exhausted SwiftUI stops
    /// requesting frames, so the `TimelineView` idles until it is re-created with a new
    /// schedule (i.e. a new horizon).
    public struct Entries: Sequence, IteratorProtocol {
        private var iterator: Array<Date>.Iterator

        init(dates: [Date]) {
            iterator = dates.makeIterator()
        }

        public mutating func next() -> Date? {
            iterator.next()
        }
    }
}
