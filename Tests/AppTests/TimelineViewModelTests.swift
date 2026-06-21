@testable import App
import Domain
import Persistence
import Testing

@Suite("TimelineViewModel (VCR playback composition)")
@MainActor
struct TimelineViewModelTests {
    /// `now` for the seeded fixtures — observations are placed relative to it.
    private static let now = Instant(nanosecondsSinceEpoch: 1_700_000_000_000_000_000)

    /// A store with a positioned gateway + source and `count` observations spaced
    /// `spacingSeconds` apart, ending `endOffset` seconds before `now`.
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

    @Test
    func `load builds nodes, window and starts live at the window end`() async throws {
        let viewModel = try await model(seededStore())
        try await viewModel.load()
        #expect(viewModel.nodes.count == 2)
        #expect(viewModel.mode == .live)
        #expect(viewModel.playhead == viewModel.window.end)
        #expect(viewModel.window.buckets.reduce(0, +) == 3) // all 3 observations in window
    }

    @Test
    func `scrubbing into the past enters review and reconstructs fewer traces`() async throws {
        let viewModel = try await model(seededStore(count: 3, spacingSeconds: 600, endOffset: 600))
        try await viewModel.load()
        // Scrub to the very start: nothing has arrived yet.
        viewModel.scrub(toFraction: 0)
        #expect(viewModel.mode == .review)
        #expect(viewModel.traces.isEmpty)
        // Scrub to the end: all three packets are active.
        viewModel.scrub(toFraction: 1)
        #expect(viewModel.mode == .live)
        #expect(viewModel.traces.count == 3)
    }

    @Test
    func `seeking to the middle shows only the arrived packets`() async throws {
        let viewModel = try await model(seededStore(count: 3, spacingSeconds: 600, endOffset: 600))
        try await viewModel.load()
        // Seek to just after the first observation (window end - 1800s ... the
        // first obs is at end-1800, second at end-1200, third at end-600).
        viewModel.seek(to: viewModel.window.end.adding(seconds: -1500))
        #expect(viewModel.mode == .review)
        #expect(viewModel.traces.count == 1)
    }

    @Test
    func `play then tick advances the playhead and surfaces more traces`() async throws {
        let viewModel = try await model(seededStore(count: 3, spacingSeconds: 600, endOffset: 600))
        try await viewModel.load()
        viewModel.scrub(toFraction: 0) // back to the start, review mode
        viewModel.play()
        #expect(viewModel.isPlaying)
        let before = viewModel.traces.count
        // Advance well past all observations at 4× — should reach live + show all.
        viewModel.setSpeed(.four)
        viewModel.tick(delta: TimelineWindowBuilder.dayInSeconds) // huge step → end
        #expect(viewModel.traces.count >= before)
        #expect(viewModel.mode == .live) // ran off the end → returned to live
        #expect(!viewModel.isPlaying)
    }

    @Test
    func `tick does nothing when paused or live`() async throws {
        let viewModel = try await model(seededStore())
        try await viewModel.load()
        let pinned = viewModel.playhead
        viewModel.tick(delta: 100) // live + not playing
        #expect(viewModel.playhead == pinned)
        viewModel.scrub(toFraction: 0.3)
        let scrubbed = viewModel.playhead
        viewModel.tick(delta: 100) // review but paused
        #expect(viewModel.playhead == scrubbed)
    }

    @Test
    func `goLive pins the playhead to the window end and pauses`() async throws {
        let viewModel = try await model(seededStore())
        try await viewModel.load()
        viewModel.scrub(toFraction: 0.2)
        viewModel.play()
        viewModel.goLive()
        #expect(viewModel.mode == .live)
        #expect(!viewModel.isPlaying)
        #expect(viewModel.playhead == viewModel.window.end)
    }

    @Test
    func `speed changes rescale the animation clock at a fixed playhead`() async throws {
        let viewModel = try await model(seededStore(count: 1, spacingSeconds: 600, endOffset: 600))
        try await viewModel.load()
        viewModel.seek(to: viewModel.window.end) // playhead after the single packet
        let clockAtOne = viewModel.clock
        viewModel.setSpeed(.four)
        #expect(viewModel.clock == clockAtOne * 4)
    }
}
