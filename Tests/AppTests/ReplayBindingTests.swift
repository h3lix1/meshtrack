// ReplayBindingTests — item 1: the VCR bar must drive the map during review.
//
// The bug was that scrubbing updated the timeline's internal state but never exposed
// the reconstructed traces for the playhead back to the map, so the map kept showing
// live data. These tests pin the contract the lead binds against: `isReviewing` flips
// true when scrubbed off live, the reconstructed `traces`/`nodes` track the playhead,
// and returning to live flips it back so the live feed takes over.

@testable import App
import Domain
import Persistence
import Testing

@Suite("Replay binding (VCR drives the map)")
@MainActor
struct ReplayBindingTests {
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
    func `isReviewing is false at live and true once scrubbed off the end`() async throws {
        let viewModel = try await model(seededStore())
        try await viewModel.load()
        #expect(!viewModel.isReviewing) // pinned live on load
        viewModel.scrub(toFraction: 0.3)
        #expect(viewModel.isReviewing) // scrubbed into the past
        viewModel.goLive()
        #expect(!viewModel.isReviewing) // back to live, feed reverts
    }

    @Test
    func `scrubbing exposes the reconstructed traces for the playhead`() async throws {
        // The whole point of item 1: the map binds to these, so they must reflect the
        // playhead, not the live tail.
        let viewModel = try await model(seededStore(count: 3, spacingSeconds: 600, endOffset: 600))
        try await viewModel.load()

        viewModel.scrub(toFraction: 0) // before anything arrived
        #expect(viewModel.isReviewing)
        #expect(viewModel.traces.isEmpty)

        // Seek to just after the first observation: exactly one trace is reconstructed.
        viewModel.seek(to: viewModel.window.end.adding(seconds: -1500))
        #expect(viewModel.isReviewing)
        #expect(viewModel.traces.count == 1)

        // Seek to the end: all three are active and we re-enter live.
        viewModel.seek(to: viewModel.window.end)
        #expect(!viewModel.isReviewing)
        #expect(viewModel.traces.count == 3)
    }

    @Test
    func `nodes stay available for the map throughout review`() async throws {
        let viewModel = try await model(seededStore())
        try await viewModel.load()
        let liveNodes = viewModel.nodes
        viewModel.scrub(toFraction: 0.2)
        // The fleet the map draws must not vanish when reviewing.
        #expect(viewModel.nodes == liveNodes)
        #expect(!viewModel.nodes.isEmpty)
    }

    @Test
    func `ticking while playing review keeps reconstructing until it runs to live`() async throws {
        let viewModel = try await model(seededStore(count: 3, spacingSeconds: 600, endOffset: 600))
        try await viewModel.load()
        viewModel.scrub(toFraction: 0)
        viewModel.play()
        #expect(viewModel.isReviewing)
        let early = viewModel.traces.count
        viewModel.setSpeed(.four)
        viewModel.tick(delta: 1500) // advance partway
        #expect(viewModel.isReviewing)
        #expect(viewModel.traces.count >= early)
        viewModel.tick(delta: TimelineWindowBuilder.dayInSeconds) // run off the end
        #expect(!viewModel.isReviewing) // returned to live
    }

    @Test
    func `focused packet replay exposes a moving frame clock for the map binding`() async throws {
        let viewModel = try await model(seededStore(count: 2, spacingSeconds: 600, endOffset: 600))
        try await viewModel.load()
        #expect(viewModel.focusPacket(0xA1, autoplay: true))
        #expect(viewModel.isReviewing)
        #expect(viewModel.traces.map(\.id) == [0xA1])

        let startClock = viewModel.clock
        viewModel.tick(delta: 0.5)

        #expect(viewModel.clock > startClock)
        #expect(viewModel.traces.map(\.id) == [0xA1])
        viewModel.goLive()
        #expect(!viewModel.isReviewing)
        #expect(viewModel.focusedPacketID == nil)
    }
}
