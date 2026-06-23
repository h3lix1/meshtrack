// Tests for TraceAnimationSchedule — the demand-driven, ~30fps, finite TimelineSchedule
// that replaces TimelineView(.animation)'s continuous full-refresh-rate repaints.

@testable import App
import Domain
import SwiftUI
import Testing

@Suite("TraceAnimationSchedule.horizon")
struct TraceAnimationScheduleHorizonTests {
    private func point(_ lat: Double, _ lon: Double) -> GeoPoint {
        GeoPoint(latitude: lat, longitude: lon)
    }

    /// A trace with `edgeCount` hop-1..N edges fanning out, started at `startedAt`.
    private func trace(id: UInt32, startedAt: Double, edgeCount: Int, hops: Int) -> PacketTrace {
        let edges = (1 ... max(edgeCount, 1)).map { hop in
            TraceEdge(from: point(0, 0), to: point(Double(hop), Double(hop)), kind: .observed, hopIndex: hop)
        }
        return PacketTrace(id: id, sourceNode: 1, edges: edges, hops: hops, startedAt: startedAt)
    }

    @Test
    func `empty traces yield the nothing-pending sentinel`() {
        let h = TraceAnimationSchedule.horizon(for: [], hopDuration: 0.5, mode: .sequential)
        #expect(h == TraceAnimationSchedule.nothingPending)
        #expect(h == -.infinity)
    }

    @Test
    func `sequential horizon scales with hop count`() {
        // Two traces: one 3-hop @ t=10, one 2-hop @ t=12. hopDuration 0.5s.
        // Sequential journeyDuration = edgeCount * hopDuration.
        //   trace A finishes at 10 + 3*0.5 = 11.5
        //   trace B finishes at 12 + 2*0.5 = 13.0  ← max
        let a = trace(id: 1, startedAt: 10, edgeCount: 3, hops: 3)
        let b = trace(id: 2, startedAt: 12, edgeCount: 2, hops: 2)
        let h = TraceAnimationSchedule.horizon(for: [a, b], hopDuration: 0.5, mode: .sequential)
        #expect(abs(h - 13.0) < 1e-9)
    }

    @Test
    func `equaliseFinish horizon is one hopDuration regardless of hop count`() {
        // equaliseFinish journeyDuration is a single hopDuration (when edgeCount > 0).
        //   trace A finishes at 10 + 0.5 = 10.5
        //   trace B finishes at 12 + 0.5 = 12.5 ← max
        let a = trace(id: 1, startedAt: 10, edgeCount: 4, hops: 4)
        let b = trace(id: 2, startedAt: 12, edgeCount: 1, hops: 1)
        let h = TraceAnimationSchedule.horizon(for: [a, b], hopDuration: 0.5, mode: .equaliseFinish)
        #expect(abs(h - 12.5) < 1e-9)
    }

    @Test
    func `horizon uses max(maxHopIndex, hops) so a collapsed multi-hop path isn't understated`() {
        // A 5-hop packet drawn as a SINGLE hop-1 edge: maxHopIndex == 1 but hops == 5.
        // Sequential duration must use 5, not 1: 0 + 5*0.5 = 2.5 (not 0.5).
        let edge = TraceEdge(from: point(0, 0), to: point(1, 1), kind: .observed, hopIndex: 1)
        let collapsed = PacketTrace(id: 9, sourceNode: 1, edges: [edge], hops: 5, startedAt: 0)
        #expect(collapsed.maxHopIndex == 1)
        let h = TraceAnimationSchedule.horizon(for: [collapsed], hopDuration: 0.5, mode: .sequential)
        #expect(abs(h - 2.5) < 1e-9)
    }
}

@Suite("TraceAnimationSchedule.frameDates")
struct TraceAnimationScheduleFrameTests {
    private func date(_ t: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: t)
    }

    @Test
    func `frames are spaced ~frameInterval apart and end just past the horizon`() throws {
        let interval = 1.0 / 30.0
        let horizon = 5.0
        let schedule = TraceAnimationSchedule(horizon: horizon, frameInterval: interval)
        let start = date(2.0)
        let dates = schedule.frameDates(from: start)

        // Finite + non-trivial: a multi-second animation produces many frames.
        #expect(dates.count > 1)
        #expect(dates.count < TraceAnimationSchedule.maxFrames + 2)

        // First frame is exactly the start.
        #expect(dates.first == start)

        // Consecutive frames are spaced by frameInterval.
        for i in 1 ..< dates.count {
            let gap = dates[i].timeIntervalSinceReferenceDate - dates[i - 1].timeIntervalSinceReferenceDate
            #expect(abs(gap - interval) < 1e-9)
        }

        // The last frame is at or just past the horizon (within one interval past it),
        // so the completed final frame is drawn — but it never runs unboundedly on.
        let last = try #require(dates.last).timeIntervalSinceReferenceDate
        #expect(last >= horizon)
        #expect(last <= horizon + interval + 1e-9)

        // The penultimate frame is at or before the horizon, confirming the final frame
        // is the FIRST one strictly past it — we stop one interval past rather than
        // continuing forever. (When the span divides evenly the penultimate lands
        // exactly on the horizon.)
        let penultimate = dates[dates.count - 2].timeIntervalSinceReferenceDate
        #expect(penultimate <= horizon)
        #expect(last > horizon)
    }

    @Test
    func `a start already past the horizon yields exactly one frame`() {
        let schedule = TraceAnimationSchedule(horizon: 5.0)
        let dates = schedule.frameDates(from: date(5.0)) // exactly at horizon → finished
        #expect(dates.count == 1)
        #expect(dates.first == date(5.0))

        let later = schedule.frameDates(from: date(9.0)) // well past
        #expect(later.count == 1)
        #expect(later.first == date(9.0))
    }

    @Test
    func `the nothing-pending sentinel yields exactly one frame`() {
        let schedule = TraceAnimationSchedule(horizon: TraceAnimationSchedule.nothingPending)
        let dates = schedule.frameDates(from: date(0))
        #expect(dates.count == 1)
        #expect(dates.first == date(0))
    }

    @Test
    func `the paused/static variant yields exactly one frame`() {
        let schedule = TraceAnimationSchedule.paused
        #expect(schedule.isStatic)
        let dates = schedule.frameDates(from: date(3.0))
        #expect(dates.count == 1)
        #expect(dates.first == date(3.0))
    }

    @Test
    func `a non-nothing-pending static schedule still yields exactly one frame`() {
        // Even with a future horizon, isStatic short-circuits to a single frame so the
        // externally-driven (replay) clock owns advancement.
        let schedule = TraceAnimationSchedule(horizon: 100.0, isStatic: true)
        let dates = schedule.frameDates(from: date(0))
        #expect(dates.count == 1)
    }

    @Test
    func `entries(from:) returns the same finite frame stream as frameDates`() {
        let schedule = TraceAnimationSchedule(horizon: 1.0)
        let start = date(0)
        let expected = schedule.frameDates(from: start)
        let actual = Array(schedule.entries(from: start, mode: .normal))
        #expect(actual == expected)
    }
}
