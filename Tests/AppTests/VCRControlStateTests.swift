@testable import App
import Domain
import Persistence
import Testing

@Suite("VCR control state bridge")
@MainActor
struct VCRControlStateTests {
    private static let now = Instant(nanosecondsSinceEpoch: 1_700_000_000_000_000_000)

    private func loadedModel() async throws -> TimelineViewModel {
        let store = try MeshStore(DatabaseConnection.inMemory())
        try await store.upsertNode(NodeRecord(
            node_num: 0x0000_00FF, hexid: "!000000ff", short_name: "GW",
            node_class: .gateway, first_seen_at: 0, last_heard_at: 0
        ))
        _ = try await store.appendPositionFix(PositionFixRecord(
            node_num: 0x0000_00FF, t: 1, lat: 37.5, lon: -122.0
        ))
        try await store.recordObservation(ObservationRecord(
            node_num: 0x0000_0001, packet_id: 0xAA, transport: .mqtt, gateway_id: "!000000ff",
            rx_time: Self.now.adding(seconds: -3600).nanosecondsSinceEpoch, hop_start: 1, hop_limit: 0
        ))
        let viewModel = TimelineViewModel(store: store, clock: InjectedClock(Self.now))
        try await viewModel.load()
        return viewModel
    }

    @Test
    func `live state reports LIVE and a full playhead`() async throws {
        let viewModel = try await loadedModel()
        let state = viewModel.controlState
        #expect(state.isLive)
        #expect(state.playheadLabel == "LIVE")
        #expect(state.playheadFraction == 1)
        #expect(state.buckets.count == 96)
    }

    @Test
    func `reviewing reports a negative time-ago label`() async throws {
        let viewModel = try await loadedModel()
        // Seek 2h12m before the window end.
        viewModel.seek(to: viewModel.window.end.adding(seconds: -(2 * 3600 + 12 * 60)))
        let state = viewModel.controlState
        #expect(!state.isLive)
        #expect(state.playheadLabel == "-2h12m")
        #expect(state.playheadFraction < 1)
        #expect(state.speed == viewModel.speed)
    }

    @Test
    func `sub-hour review uses a minutes-only label`() async throws {
        let viewModel = try await loadedModel()
        viewModel.seek(to: viewModel.window.end.adding(seconds: -(45 * 60)))
        #expect(viewModel.controlState.playheadLabel == "-45m")
    }
}
