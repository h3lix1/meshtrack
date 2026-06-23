@testable import App
import Domain
import Testing

@Suite("Replay reconstruction (pure, deterministic)")
struct ReplayReconstructorTests {
    private let positions: [Int64: GeoPoint] = [
        0x0000_0001: GeoPoint(latitude: 37.0, longitude: -122.0), // source
        0x0000_00FF: GeoPoint(latitude: 37.5, longitude: -122.0), // gateway A
        0x0000_00EE: GeoPoint(latitude: 37.3, longitude: -121.8) // gateway B
    ]

    private func observation(
        id: UInt32,
        gateway: Int64?,
        atSeconds seconds: Double,
        relayNode: UInt8 = 0
    ) -> TimelineObservation {
        TimelineObservation(
            packetID: id, fromNode: 0x0000_0001, gatewayNode: gateway,
            relayNode: relayNode, hopStart: 3, hopLimit: 1,
            rxTime: Instant.epoch.adding(seconds: seconds)
        )
    }

    @Test
    func `playhead before any observation yields an empty frame`() {
        let engine = ReplayReconstructor()
        let frame = engine.frame(
            observations: [observation(id: 0xAA, gateway: 0x0000_00FF, atSeconds: 100)],
            playhead: Instant.epoch.adding(seconds: 50),
            speed: .one,
            positions: positions
        )
        #expect(frame == .empty)
    }

    @Test
    func `only observations up to the playhead are reconstructed`() {
        let engine = ReplayReconstructor()
        let corpus = [
            observation(id: 0x01, gateway: 0x0000_00FF, atSeconds: 10),
            observation(id: 0x02, gateway: 0x0000_00FF, atSeconds: 20),
            observation(id: 0x03, gateway: 0x0000_00FF, atSeconds: 30)
        ]
        let frame = engine.frame(
            observations: corpus,
            playhead: Instant.epoch.adding(seconds: 25),
            speed: .one,
            positions: positions
        )
        #expect(frame.traces.map(\.id).sorted() == [0x01, 0x02]) // 0x03 not yet arrived
    }

    @Test
    func `the same packet via two gateways stays one trace with two edges`() {
        let engine = ReplayReconstructor()
        let corpus = [
            observation(id: 0xAA, gateway: 0x0000_00FF, atSeconds: 10),
            observation(id: 0xAA, gateway: 0x0000_00EE, atSeconds: 11)
        ]
        let frame = engine.frame(
            observations: corpus,
            playhead: Instant.epoch.adding(seconds: 100),
            speed: .one,
            positions: positions
        )
        #expect(frame.traces.count == 1)
        #expect(frame.traces.first?.edges.count == 2)
    }

    @Test
    func `focused packet frame uses every reception for the selected packet only`() {
        let engine = ReplayReconstructor()
        let corpus = [
            observation(id: 0xAA, gateway: 0x0000_00FF, atSeconds: 10),
            observation(id: 0xBB, gateway: 0x0000_00FF, atSeconds: 11),
            observation(id: 0xAA, gateway: 0x0000_00EE, atSeconds: 12)
        ]
        let frame = engine.focusedPacketFrame(
            observations: corpus,
            packetID: 0xAA,
            clock: 1.25,
            positions: positions
        )
        #expect(frame.clock == 1.25)
        #expect(frame.traces.map(\.id) == [0xAA])
        #expect(frame.traces.first?.edges.count == 2)
    }

    @Test
    func `replay suppresses ambiguous relay guesses when requested`() {
        let engine = ReplayReconstructor()
        let ambiguousPositions = positions.merging([
            0x0000_0011: GeoPoint(latitude: 37.2, longitude: -122.0),
            0x0000_0111: GeoPoint(latitude: 37.25, longitude: -122.0)
        ]) { _, new in new }
        let corpus = [
            observation(id: 0xAA, gateway: 0x0000_00FF, atSeconds: 10, relayNode: 0x11)
        ]

        let defaultFrame = engine.frame(
            observations: corpus,
            playhead: Instant.epoch.adding(seconds: 100),
            speed: .one,
            positions: ambiguousPositions
        )
        #expect(defaultFrame.traces.first?.edges.map(\.kind) == [.guessed, .observed])

        let suppressedFrame = engine.frame(
            observations: corpus,
            playhead: Instant.epoch.adding(seconds: 100),
            speed: .one,
            positions: ambiguousPositions,
            relayGuessing: .unambiguousOnly
        )
        #expect(suppressedFrame.traces.first?.edges.map(\.kind) == [.observed])

        let allCandidatesFrame = engine.frame(
            observations: corpus,
            playhead: Instant.epoch.adding(seconds: 100),
            speed: .one,
            positions: ambiguousPositions,
            relayGuessing: .allCandidates
        )
        let allCandidateTrace = allCandidatesFrame.traces.first
        #expect(allCandidateTrace?.edges.map(\.kind) == [.guessed, .observed, .guessed, .observed])
        #expect(allCandidateTrace?.receivers.count(where: { $0.kind == .relay }) == 2)
    }

    @Test
    func `focused packet frame is empty for an unknown packet`() {
        let engine = ReplayReconstructor()
        let frame = engine.focusedPacketFrame(
            observations: [observation(id: 0xAA, gateway: 0x0000_00FF, atSeconds: 10)],
            packetID: 0xCC,
            clock: 3,
            positions: positions
        )
        #expect(frame == .empty)
    }

    @Test
    func `the sliding window evicts the oldest packets beyond the cap`() {
        let engine = ReplayReconstructor(windowSize: 3)
        let corpus = (1 ... 6)
            .map { observation(id: UInt32($0), gateway: 0x0000_00FF, atSeconds: Double($0)) }
        let frame = engine.frame(
            observations: corpus,
            playhead: Instant.epoch.adding(seconds: 100),
            speed: .one,
            positions: positions
        )
        #expect(frame.traces.map(\.id).sorted() == [4, 5, 6])
    }

    @Test
    func `clock is elapsed-since-oldest scaled by speed`() {
        let engine = ReplayReconstructor(windowSize: 12)
        let corpus = [observation(id: 0xAA, gateway: 0x0000_00FF, atSeconds: 100)]
        let playhead = Instant.epoch.adding(seconds: 130) // 30s after oldest

        let atOne = engine.frame(observations: corpus, playhead: playhead, speed: .one, positions: positions)
        #expect(atOne.clock == 30)

        let atFour = engine.frame(
            observations: corpus,
            playhead: playhead,
            speed: .four,
            positions: positions
        )
        #expect(atFour.clock == 120) // 30 * 4

        let atHalf = engine.frame(
            observations: corpus,
            playhead: playhead,
            speed: .half,
            positions: positions
        )
        #expect(atHalf.clock == 15) // 30 * 0.5
    }

    @Test
    func `reconstruction is deterministic regardless of input order`() {
        let engine = ReplayReconstructor()
        let ordered = [
            observation(id: 0x01, gateway: 0x0000_00FF, atSeconds: 10),
            observation(id: 0x02, gateway: 0x0000_00EE, atSeconds: 20),
            observation(id: 0x03, gateway: 0x0000_00FF, atSeconds: 30)
        ]
        let shuffled = [ordered[2], ordered[0], ordered[1]]
        let playhead = Instant.epoch.adding(seconds: 100)
        let a = engine.frame(observations: ordered, playhead: playhead, speed: .two, positions: positions)
        let b = engine.frame(observations: shuffled, playhead: playhead, speed: .two, positions: positions)
        #expect(a == b)
    }
}

@Suite("Timeline window + speed model")
struct TimelineModelTests {
    @Test
    func `window buckets observations across the 24h span`() {
        let now = Instant.epoch.adding(seconds: TimelineWindowBuilder.dayInSeconds)
        // one at the very start, one near the end.
        let corpus = [
            TimelineObservation(
                packetID: 1, fromNode: 1, gatewayNode: 2, relayNode: 0, hopStart: 1, hopLimit: 0,
                rxTime: Instant.epoch.adding(seconds: 1)
            ),
            TimelineObservation(
                packetID: 2, fromNode: 1, gatewayNode: 2, relayNode: 0, hopStart: 1, hopLimit: 0,
                rxTime: now.adding(seconds: -1)
            )
        ]
        let window = TimelineWindowBuilder.build(observations: corpus, now: now, bucketCount: 24)
        #expect(window.buckets.count == 24)
        #expect(window.buckets.first == 1)
        #expect(window.buckets.last == 1)
        #expect(window.buckets.reduce(0, +) == 2)
    }

    @Test
    func `observations outside the window are dropped`() {
        let now = Instant.epoch.adding(seconds: TimelineWindowBuilder.dayInSeconds)
        let stale = TimelineObservation(
            packetID: 9, fromNode: 1, gatewayNode: 2, relayNode: 0, hopStart: 1, hopLimit: 0,
            rxTime: Instant.epoch.adding(seconds: -3600) // before the window start
        )
        let window = TimelineWindowBuilder.build(observations: [stale], now: now, bucketCount: 24)
        #expect(window.buckets.reduce(0, +) == 0)
    }

    @Test
    func `fraction and instant round-trip across the window`() {
        let now = Instant.epoch.adding(seconds: TimelineWindowBuilder.dayInSeconds)
        let window = TimelineWindowBuilder.build(observations: [], now: now)
        let mid = window.instant(atFraction: 0.5)
        #expect(abs(window.fraction(of: mid) - 0.5) < 1e-9)
        #expect(window.fraction(of: window.start) == 0)
        #expect(window.fraction(of: window.end) == 1)
    }

    @Test
    func `speed steps clamp at the ends`() {
        #expect(PlaybackSpeed.four.faster == .four)
        #expect(PlaybackSpeed.half.slower == .half)
        #expect(PlaybackSpeed.one.faster == .two)
        #expect(PlaybackSpeed.two.slower == .one)
        #expect(PlaybackSpeed.allCases == [.half, .one, .two, .four])
    }
}
