@testable import Domain
import Testing

@Suite("DedupWindow (SPEC §2.4)")
struct DedupWindowTests {
    private let key = DedupKey(packetID: 0xDEAD_BEEF, fromNode: 0xA1B2_C3D4)
    private func at(_ seconds: Double) -> Instant {
        Instant.epoch.adding(seconds: seconds)
    }

    // `admit` is mutating, which #expect can't call inline — capture results first.

    @Test
    func `the first sighting of a packet is admitted`() {
        var window = DedupWindow(windowSeconds: 600)
        let admitted = window.admit(key, at: at(0))
        #expect(admitted)
        #expect(window.trackedCount == 1)
    }

    @Test
    func `an immediate repeat is a duplicate`() {
        var window = DedupWindow(windowSeconds: 600)
        let first = window.admit(key, at: at(0))
        let second = window.admit(key, at: at(0))
        #expect(first)
        #expect(!second)
    }

    @Test
    func `a repeat within the window is a duplicate`() {
        var window = DedupWindow(windowSeconds: 600)
        let first = window.admit(key, at: at(0))
        let at100 = window.admit(key, at: at(100))
        let at599 = window.admit(key, at: at(599))
        #expect(first)
        #expect(!at100)
        #expect(!at599)
    }

    @Test
    func `a sighting after the window expires is admitted again`() {
        var window = DedupWindow(windowSeconds: 600)
        let first = window.admit(key, at: at(0))
        let afterWindow = window.admit(key, at: at(601))
        #expect(first)
        #expect(afterWindow)
        #expect(window.trackedCount == 1) // stale entry evicted, new one tracked
    }

    @Test
    func `repeats slide the window forward from the last sighting`() {
        var window = DedupWindow(windowSeconds: 600)
        let first = window.admit(key, at: at(0))
        let at500 = window.admit(key, at: at(500)) // dup; slides last-seen to 500
        // 900s from t0 is > 600, but only 400s since the t=500 sighting → still a dup.
        let at900 = window.admit(key, at: at(900))
        #expect(first)
        #expect(!at500)
        #expect(!at900)
    }

    @Test
    func `different from_node with the same packet_id are independent`() {
        var window = DedupWindow(windowSeconds: 600)
        let other = DedupKey(packetID: key.packetID, fromNode: 0x0000_0009)
        let a = window.admit(key, at: at(0))
        let b = window.admit(other, at: at(0))
        #expect(a)
        #expect(b)
        #expect(window.trackedCount == 2)
    }

    @Test
    func `different packet_id from the same node are independent`() {
        var window = DedupWindow(windowSeconds: 600)
        let other = DedupKey(packetID: 0x0000_0001, fromNode: key.fromNode)
        let a = window.admit(key, at: at(0))
        let b = window.admit(other, at: at(0))
        #expect(a)
        #expect(b)
    }

    @Test
    func `admitting many copies within the window yields exactly one admit`() {
        var window = DedupWindow(windowSeconds: 600)
        var admits = 0
        for second in stride(from: 0.0, through: 500.0, by: 50.0) where window.admit(key, at: at(second)) {
            admits += 1
        }
        #expect(admits == 1)
    }
}
