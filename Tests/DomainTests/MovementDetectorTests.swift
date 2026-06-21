@testable import Domain
import Testing

@Suite("MovementDetector (SPEC §2.3)")
struct MovementDetectorTests {
    private let anchor = GeoPoint(latitude: 37.0, longitude: -122.0)

    private func north(_ meters: Double) -> GeoPoint {
        GeoPoint(latitude: anchor.latitude + meters / 111_320.0, longitude: anchor.longitude)
    }

    private func fix(_ meters: Double, accuracy: Double = 10) -> PositionSample {
        PositionSample(point: north(meters), horizontalAccuracyMeters: accuracy, at: .epoch)
    }

    private func detector(threshold: Double = 100, anchorAccuracy: Double = 10) -> MovementDetector {
        MovementDetector(
            anchor: anchor,
            anchorAccuracyMeters: anchorAccuracy,
            config: MovementConfig(thresholdMeters: threshold)
        )
    }

    @Test
    func `jitter inside the accuracy envelope never confirms movement (zero false positives)`() {
        var detector = detector()
        var events: [MovementEvent] = []
        for _ in 0 ..< 5 {
            if let event = detector.ingest(fix(40, accuracy: 60)) { events.append(event) }
        }
        #expect(events.isEmpty)
        #expect(detector.state == .anchored)
    }

    @Test
    func `a confirmed move fires exactly one moved event`() {
        var detector = detector()
        var events: [MovementEvent] = []
        for _ in 0 ..< 6 {
            if let event = detector.ingest(fix(150)) { events.append(event) }
        }
        #expect(events == [.moved])
        #expect(detector.state == .moved)
    }

    @Test
    func `a single large fix escapes and confirms immediately`() {
        var detector = detector()
        let event = detector.ingest(fix(600))
        #expect(event == .moved)
    }

    @Test
    func `a coarse fix (accuracy > threshold) is ignored`() {
        var detector = detector()
        let event = detector.ingest(fix(500, accuracy: 200))
        #expect(event == nil)
        #expect(detector.state == .anchored)
    }

    @Test
    func `hysteresis: oscillating near the threshold does not flap`() {
        var detector = detector()
        for _ in 0 ..< 3 {
            _ = detector.ingest(fix(150))
        } // confirm moved
        #expect(detector.state == .moved)

        var returns: [MovementEvent] = []
        for meters in [90.0, 70.0, 90.0, 80.0, 90.0] { // all above returnThreshold (60m)
            if let event = detector.ingest(fix(meters)) { returns.append(event) }
        }
        #expect(returns.isEmpty)
        #expect(detector.state == .moved)
    }

    @Test
    func `returns only after sustained re-entry inside threshold * returnRatio`() {
        var detector = detector()
        for _ in 0 ..< 3 {
            _ = detector.ingest(fix(150))
        }
        var events: [MovementEvent] = []
        for _ in 0 ..< 3 {
            if let event = detector.ingest(fix(30)) { events.append(event) } // 30m < 60m
        }
        #expect(events == [.returned])
        #expect(detector.state == .anchored)
    }

    @Test
    func `a single candidate spike below the escape factor does not confirm`() {
        var detector = detector()
        let first = detector.ingest(fix(150)) // 1 candidate, need 3
        let backInside = detector.ingest(fix(10)) // resets the streak
        let again = detector.ingest(fix(150)) // 1 candidate again
        #expect(first == nil)
        #expect(backInside == nil)
        #expect(again == nil)
        #expect(detector.state == .anchored)
    }
}
