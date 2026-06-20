@testable import Domain
import Testing

@Suite("Clock & Instant")
struct ClockTests {
    @Test
    func `InjectedClock is deterministic and advances exactly`() {
        let clock = InjectedClock(Instant(nanosecondsSinceEpoch: 1_000_000_000))
        #expect(clock.now().nanosecondsSinceEpoch == 1_000_000_000)
        clock.advance(seconds: 5)
        #expect(clock.now() == Instant(nanosecondsSinceEpoch: 6_000_000_000))
    }

    @Test
    func `InjectedClock can be pinned to an exact instant`() {
        let clock = InjectedClock()
        #expect(clock.now() == .epoch)
        clock.set(Instant(nanosecondsSinceEpoch: 42))
        #expect(clock.now().nanosecondsSinceEpoch == 42)
    }

    @Test
    func `Instant ordering is by nanoseconds`() {
        let a = Instant(nanosecondsSinceEpoch: 0)
        let b = Instant(nanosecondsSinceEpoch: 1)
        #expect(a < b)
        #expect(max(a, b) == b)
    }

    @Test
    func `Instant arithmetic round-trips through seconds`() {
        let base = Instant.epoch
        let later = base.adding(seconds: 1.5)
        #expect(later > base)
        #expect(abs(later.secondsSince(base) - 1.5) < 1e-9)

        let earlier = base.adding(seconds: -2)
        #expect(earlier < base)
        #expect(abs(earlier.secondsSince(base) + 2) < 1e-9)
    }
}
