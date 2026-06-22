// TraceTiming — the pure, MapKit-independent geometry that times a packet trace's
// animated draw (SPEC §1.6 "timed line draw, configurable, equal finish"). This is
// the shared math the live MapKit overlay and the headless Canvas both consume, so
// it is the piece CI exercises (MKMapView can't render headless — ADR 0007). No
// SwiftUI/MapKit imports: just CoreGraphics points and Domain edges.
//
// Two timing modes:
//  - Sequential (default): each edge draws over a fixed `hopDuration`, hop N+1
//    starting when hop N completes. Per-edge speed varies with edge length.
//  - Equalise-finish: every edge of one journey *finishes together*. All edges
//    start at the journey origin and complete after a single `hopDuration`, so a
//    shorter hop draws slower (fewer metres ÷ same time) and the whole journey lands
//    as one synchronised front.

import CoreGraphics
import Domain

/// Whether a journey's hops draw one-after-another or all finish together.
public enum TraceTimingMode: Sendable, Equatable {
    /// Hop N+1 begins when hop N completes; each hop takes `hopDuration`.
    case sequential
    /// Every hop finishes simultaneously after one `hopDuration` (shorter = slower).
    case equaliseFinish
}

/// Pure timing/geometry for animating a single trace. Deterministic and Sendable.
public enum TraceTiming {
    /// Fraction [0, 1] that edges at hop number `hopIndex` (1-based) should be drawn
    /// at animation time `clock`, for a trace that began at `startedAt`.
    ///
    /// Hop number — not edge position — drives the delay, so EVERY edge sharing a hop
    /// number animates concurrently: hop 1 of every path draws first, then hop 2, … so
    /// the wavefront expands ring-by-ring (item 2). A trace with parallel paths whose
    /// hop-1 edges fan out from the source now lights them all at once instead of one
    /// edge at a time.
    ///
    /// - Sequential: hop `n` is delayed by `(n-1) * hopDuration`, then draws linearly
    ///   over `hopDuration`.
    /// - Equalise-finish: all edges share the same [startedAt, startedAt+hopDuration]
    ///   window, so the whole journey completes together regardless of hop count.
    public static func edgeProgress(
        clock: Double,
        startedAt: Double,
        hopIndex: Int,
        hopDuration: Double,
        mode: TraceTimingMode
    ) -> Double {
        let duration = max(hopDuration, .leastNonzeroMagnitude)
        let delay: Double = switch mode {
        case .sequential:
            Double(max(0, hopIndex - 1)) * duration
        case .equaliseFinish:
            0
        }
        let elapsed = clock - startedAt - delay
        return clamp01(elapsed / duration)
    }

    /// Total wall-clock seconds a journey of `edgeCount` hops takes to finish, from
    /// `startedAt`. Equalise-finish is always one `hopDuration`; sequential scales
    /// with hop count.
    public static func journeyDuration(
        edgeCount: Int,
        hopDuration: Double,
        mode: TraceTimingMode
    ) -> Double {
        let duration = max(hopDuration, 0)
        switch mode {
        case .sequential:
            return Double(max(0, edgeCount)) * duration
        case .equaliseFinish:
            return edgeCount <= 0 ? 0 : duration
        }
    }

    /// Effective draw speed of one edge in metres per second, given its length. This
    /// is what makes shorter hops "draw slower" under equalise-finish: every edge is
    /// allotted the same time, so speed = length ÷ time. Returns 0 for a
    /// zero-duration window. Used for tests / tooltips, not required for rendering.
    public static func edgeSpeedMetersPerSecond(
        lengthMeters: Double,
        hopDuration: Double
    ) -> Double {
        let duration = max(hopDuration, 0)
        guard duration > 0 else { return 0 }
        return max(0, lengthMeters) / duration
    }

    /// Linear interpolation between two points (north-up screen space).
    public static func lerp(_ from: CGPoint, _ to: CGPoint, _ fraction: Double) -> CGPoint {
        let t = clamp01(fraction)
        return CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
    }

    /// The animation-head point for edge `index` at the given progress — where the
    /// glowing spark and hop badge ride. `nil` when the edge has not started.
    public static func headPoint(
        from: CGPoint,
        to: CGPoint,
        progress: Double
    ) -> CGPoint? {
        guard progress > 0 else { return nil }
        return lerp(from, to, progress)
    }

    private static func clamp01(_ value: Double) -> Double {
        if value.isNaN { return 0 }
        return min(1, max(0, value))
    }
}
