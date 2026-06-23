@testable import App
import Domain
import Foundation
import Persistence
import Testing

// Exercises the playback *driver* path: simulating the per-frame `tick(delta:)`
// calls the view layer now emits, plus the pure frame-delta helper that clamps the
// first frame and over-long gaps. (TimelineViewModelTests covers the VM's tick math
// directly; here we drive it as the VCR control would.)

@Suite("Timeline playback driver (per-frame tick)")
@MainActor
struct TimelinePlaybackTests {
    private static let now = Instant(nanosecondsSinceEpoch: 1_700_000_000_000_000_000)

    private func seededStore(
        count: Int = 3,
        spacingSeconds: Double = 600,
        endOffset: Double = 600
    ) async throws -> MeshStore {
        let store = try MeshStore(DatabaseConnection.inMemory())
        try await store.upsertNode(NodeRecord(
            node_num: 0x0000_00FF, hexid: "!000000ff", short_name: "GW",
            node_class: .gateway, first_seen_at: 0, last_heard_at: 0
        ))
        try await store.upsertNode(NodeRecord(
            node_num: 0x0000_0001, hexid: "!00000001", short_name: "SRC",
            node_class: .mobile, first_seen_at: 0, last_heard_at: 0
        ))
        _ = try await store.appendPositionFix(PositionFixRecord(
            node_num: 0x0000_00FF, t: 1, lat: 37.5, lon: -122.0
        ))
        _ = try await store.appendPositionFix(PositionFixRecord(
            node_num: 0x0000_0001, t: 1, lat: 37.0, lon: -122.0
        ))
        for index in 0 ..< count {
            let rx = Self.now.adding(seconds: -endOffset - Double(count - 1 - index) * spacingSeconds)
            try await store.recordObservation(ObservationRecord(
                node_num: 0x0000_0001,
                packet_id: Int64(0xA0 + index),
                transport: .mqtt,
                gateway_id: "!000000ff",
                rx_time: rx.nanosecondsSinceEpoch,
                hop_start: 3,
                hop_limit: 1
            ))
        }
        return store
    }

    private func model(_ store: MeshStore) -> TimelineViewModel {
        TimelineViewModel(store: store, clock: InjectedClock(Self.now))
    }

    // MARK: Driving the VM with a stream of frame ticks

    @Test
    func `a sequence of frame ticks while playing advances the playhead fraction`() async throws {
        let viewModel = try await model(seededStore())
        try await viewModel.load()
        #expect(viewModel.focusedPacketID == nil)
        viewModel.play() // from live → review at window.start, fraction ~0
        let startFraction = viewModel.controlState.playheadFraction

        // Simulate a run of ~60Hz frames (1/60s each) for one real second.
        for _ in 0 ..< 60 {
            viewModel.tick(delta: 1.0 / 60.0)
        }

        #expect(viewModel.mode == .review)
        #expect(viewModel.isPlaying)
        #expect(viewModel.controlState.playheadFraction > startFraction)
        #expect(viewModel.playhead > viewModel.window.start)
        #expect(viewModel.playhead < viewModel.window.end)
    }

    @Test
    func `focused packet replay loops the full packet animation until paused`() async throws {
        let viewModel = try await model(seededStore(count: 1, endOffset: 600))
        try await viewModel.load()
        let didFocus = viewModel.focusPacket(0xA0, autoplay: true)

        #expect(didFocus)
        #expect(viewModel.focusedPacketID == 0xA0)
        #expect(viewModel.mode == .review)
        #expect(viewModel.isPlaying)
        #expect(viewModel.traces.map(\.id) == [0xA0])
        #expect(viewModel.clock == 0)

        viewModel.tick(delta: 1)
        #expect(abs(viewModel.clock - 1) < 1e-9)

        // This fixture's direct edge is hop 2, so the default sequential animation
        // completes at 2.4s. During the configured delay the frame stays complete.
        viewModel.tick(delta: 2)
        #expect(abs(viewModel.clock - 2.4) < 1e-9)

        viewModel.pause()
        viewModel.tick(delta: 10)
        #expect(abs(viewModel.clock - 2.4) < 1e-9)
    }

    @Test
    func `focused packet repeat delay is configurable in real seconds`() async throws {
        let viewModel = try await model(seededStore(count: 1, endOffset: 600))
        try await viewModel.load()
        viewModel.packetRepeatDelaySeconds = 4
        #expect(viewModel.focusPacket(0xA0, autoplay: true))

        viewModel.tick(delta: 5.9) // 2.4s animation + 3.5s of the 4s delay
        #expect(abs(viewModel.clock - 2.4) < 1e-9)

        viewModel.tick(delta: 0.6) // crosses 2.4 + 4.0 and restarts 0.1s into the loop
        #expect(abs(viewModel.clock - 0.1) < 1e-9)
    }

    @Test
    func `focusing an unknown packet does not enter a blank playback state`() async throws {
        let viewModel = try await model(seededStore(count: 1, endOffset: 600))
        try await viewModel.load()
        let liveTraceCount = viewModel.traces.count

        let didFocus = viewModel.focusPacket(0xDEAD_BEEF, autoplay: true)

        #expect(!didFocus)
        #expect(viewModel.focusedPacketID == nil)
        #expect(viewModel.mode == .live)
        #expect(!viewModel.isPlaying)
        #expect(viewModel.traces.count == liveTraceCount)
    }

    @Test
    func `frame ticks at higher speed advance the playhead further per second`() async throws {
        let slow = try await model(seededStore())
        try await slow.load()
        slow.play()
        for _ in 0 ..< 60 {
            slow.tick(delta: 1.0 / 60.0)
        }
        let slowFraction = slow.controlState.playheadFraction

        let fast = try await model(seededStore())
        try await fast.load()
        fast.play()
        fast.setSpeed(.four)
        for _ in 0 ..< 60 {
            fast.tick(delta: 1.0 / 60.0)
        }

        #expect(fast.controlState.playheadFraction > slowFraction)
    }

    @Test
    func `ticking to the window end returns to live and stops playing`() async throws {
        let viewModel = try await model(seededStore())
        try await viewModel.load()
        viewModel.play()
        viewModel.setSpeed(.four)

        // Span is 24h; at 4× a frame delta covering the whole span overshoots the end.
        var iterations = 0
        while viewModel.mode == .review, iterations < 10000 {
            viewModel.tick(delta: 3600) // a coarse "frame" of one hour real-time
            iterations += 1
        }

        #expect(viewModel.mode == .live)
        #expect(!viewModel.isPlaying)
        #expect(viewModel.playhead == viewModel.window.end)
        #expect(viewModel.controlState.isLive)
        #expect(viewModel.controlState.playheadFraction == 1)
    }

    // MARK: Pure frame-delta helper

    @Test
    func `the first frame yields no step so playback can't jump on the first tick`() {
        var delta = FrameDelta()
        let frame = Date(timeIntervalSinceReferenceDate: 1000)
        #expect(delta.step(to: frame) == 0)
    }

    @Test
    func `successive frames yield the real-seconds gap between them`() {
        var delta = FrameDelta()
        let base = Date(timeIntervalSinceReferenceDate: 1000)
        _ = delta.step(to: base) // prime
        let next = base.addingTimeInterval(1.0 / 60.0)
        let step = delta.step(to: next)
        #expect(abs(step - 1.0 / 60.0) < 1e-9)
    }

    @Test
    func `an over-long gap is clamped to the max step`() {
        var delta = FrameDelta()
        let base = Date(timeIntervalSinceReferenceDate: 1000)
        _ = delta.step(to: base)
        // A 5-second gap (backgrounded tab / hitch) must not pass through whole.
        let step = delta.step(to: base.addingTimeInterval(5))
        #expect(step == FrameDelta.maxStep)
    }

    @Test
    func `a zero or backwards gap yields no step`() {
        var delta = FrameDelta()
        let base = Date(timeIntervalSinceReferenceDate: 1000)
        _ = delta.step(to: base)
        #expect(delta.step(to: base) == 0) // same instant
        #expect(delta.step(to: base.addingTimeInterval(-1)) == 0) // backwards
    }
}
