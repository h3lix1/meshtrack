import Domain
import Testing

@Suite("ReceptionLatency plausibility (item 9 — skewed-RTC sanitising)")
struct LatencySanityTests {
    private func latency(seconds: Double) -> ReceptionLatency {
        let rx = Instant(nanosecondsSinceEpoch: 1_000_000_000)
        return ReceptionLatency(rxTime: rx, ingestTime: rx.adding(seconds: seconds))
    }

    @Test
    func `a small positive latency is plausible`() {
        let l = latency(seconds: 0.25)
        #expect(l.isPlausible)
        #expect(l.plausibleMillis == 250)
    }

    @Test
    func `a small negative skew is still plausible`() {
        let l = latency(seconds: -0.1)
        #expect(l.isPlausible)
        #expect(l.plausibleMillis == -100)
    }

    @Test
    func `latency at the bound is plausible (inclusive)`() {
        let l = latency(seconds: ReceptionLatency.plausibleBoundSeconds)
        #expect(l.isPlausible)
        #expect(l.plausibleMillis == Int(ReceptionLatency.plausibleBoundSeconds) * 1000)
    }

    @Test
    func `a huge positive latency from a stale RTC is implausible`() {
        // node weeks behind: latency in the billions of ms (the 4e9 bug).
        let l = latency(seconds: 7 * 24 * 3600)
        #expect(!l.isPlausible)
        #expect(l.plausibleMillis == nil)
    }

    @Test
    func `a large negative latency from a fast RTC is implausible`() {
        let l = latency(seconds: -(ReceptionLatency.plausibleBoundSeconds + 1))
        #expect(!l.isPlausible)
        #expect(l.plausibleMillis == nil)
    }

    @Test
    func `between returns nil without an ingest time`() {
        #expect(ReceptionLatency.between(rxTime: .epoch, ingestTime: nil) == nil)
    }
}
