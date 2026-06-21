@testable import App
import CoreGraphics
import Domain
import Testing

@Suite("TraceTiming — sequential vs equalise-finish")
struct TraceTimingTests {
    // MARK: Sequential

    @Test
    func `sequential edge has not started before its delay`() {
        // Edge 1 is delayed by one hopDuration; at clock 0.5 (hopDuration 1) it's 0.
        let p = TraceTiming.edgeProgress(
            clock: 0.5, startedAt: 0, edgeIndex: 1, hopDuration: 1, mode: .sequential
        )
        #expect(p == 0)
    }

    @Test
    func `sequential edge 0 draws linearly over hopDuration`() {
        let half = TraceTiming.edgeProgress(
            clock: 0.5, startedAt: 0, edgeIndex: 0, hopDuration: 1, mode: .sequential
        )
        let full = TraceTiming.edgeProgress(
            clock: 1.0, startedAt: 0, edgeIndex: 0, hopDuration: 1, mode: .sequential
        )
        #expect(abs(half - 0.5) < 1e-9)
        #expect(full == 1)
    }

    @Test
    func `sequential hops finish one after another`() {
        // At clock 1.5, edge 0 is done, edge 1 is half-drawn, edge 2 not started.
        let e0 = TraceTiming.edgeProgress(
            clock: 1.5,
            startedAt: 0,
            edgeIndex: 0,
            hopDuration: 1,
            mode: .sequential
        )
        let e1 = TraceTiming.edgeProgress(
            clock: 1.5,
            startedAt: 0,
            edgeIndex: 1,
            hopDuration: 1,
            mode: .sequential
        )
        let e2 = TraceTiming.edgeProgress(
            clock: 1.5,
            startedAt: 0,
            edgeIndex: 2,
            hopDuration: 1,
            mode: .sequential
        )
        #expect(e0 == 1)
        #expect(abs(e1 - 0.5) < 1e-9)
        #expect(e2 == 0)
    }

    // MARK: Equalise finish

    @Test
    func `equalise-finish edges all share the same progress regardless of index`() {
        // Every edge must report identical progress at any clock — that's what makes
        // them land together (shorter hops draw slower over the same window).
        let clock = 0.4
        let progresses = (0 ..< 5).map {
            TraceTiming.edgeProgress(
                clock: clock, startedAt: 0, edgeIndex: $0, hopDuration: 1, mode: .equaliseFinish
            )
        }
        for p in progresses {
            #expect(abs(p - 0.4) < 1e-9)
        }
    }

    @Test
    func `equalise-finish: a whole journey completes after one hopDuration`() {
        for edgeIndex in 0 ..< 4 {
            let p = TraceTiming.edgeProgress(
                clock: 2.0, startedAt: 0, edgeIndex: edgeIndex, hopDuration: 2, mode: .equaliseFinish
            )
            #expect(p == 1)
        }
    }

    // MARK: Journey duration

    @Test
    func `journey duration scales with hops when sequential, fixed when equalised`() {
        #expect(abs(TraceTiming.journeyDuration(edgeCount: 3, hopDuration: 1.2, mode: .sequential) - 3.6) <
            1e-9)
        #expect(TraceTiming.journeyDuration(edgeCount: 3, hopDuration: 1.2, mode: .equaliseFinish) == 1.2)
        #expect(TraceTiming.journeyDuration(edgeCount: 0, hopDuration: 1.2, mode: .equaliseFinish) == 0)
    }

    // MARK: Speed — shorter hops draw slower under equalise-finish

    @Test
    func `shorter hop draws slower for the same window`() {
        let slow = TraceTiming.edgeSpeedMetersPerSecond(lengthMeters: 100, hopDuration: 2)
        let fast = TraceTiming.edgeSpeedMetersPerSecond(lengthMeters: 1000, hopDuration: 2)
        #expect(slow == 50)
        #expect(fast == 500)
        #expect(slow < fast) // same time, fewer metres → slower
    }

    @Test
    func `zero hopDuration speed is defined (no divide-by-zero)`() {
        #expect(TraceTiming.edgeSpeedMetersPerSecond(lengthMeters: 100, hopDuration: 0) == 0)
    }

    // MARK: Clamping / robustness

    @Test
    func `progress is clamped to [0, 1] and finite for degenerate inputs`() {
        let over = TraceTiming.edgeProgress(
            clock: 100,
            startedAt: 0,
            edgeIndex: 0,
            hopDuration: 1,
            mode: .sequential
        )
        let under = TraceTiming.edgeProgress(
            clock: -100,
            startedAt: 0,
            edgeIndex: 0,
            hopDuration: 1,
            mode: .sequential
        )
        #expect(over == 1)
        #expect(under == 0)
        // hopDuration 0 must not produce NaN/inf.
        let zero = TraceTiming.edgeProgress(
            clock: 0,
            startedAt: 0,
            edgeIndex: 0,
            hopDuration: 0,
            mode: .sequential
        )
        #expect(zero.isFinite)
    }

    // MARK: Geometry helpers

    @Test
    func `lerp interpolates and clamps the fraction`() {
        let mid = TraceTiming.lerp(CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 20), 0.5)
        #expect(mid == CGPoint(x: 5, y: 10))
        let clampedHigh = TraceTiming.lerp(CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), 5)
        #expect(clampedHigh == CGPoint(x: 10, y: 0))
    }

    @Test
    func `head point is nil before the edge starts`() {
        #expect(TraceTiming.headPoint(from: .zero, to: CGPoint(x: 1, y: 1), progress: 0) == nil)
        #expect(TraceTiming.headPoint(from: .zero, to: CGPoint(x: 10, y: 0), progress: 0.5) == CGPoint(
            x: 5,
            y: 0
        ))
    }
}
