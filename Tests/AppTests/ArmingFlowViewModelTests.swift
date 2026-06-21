@testable import App
import Domain
import Persistence
import Testing

@Suite("ArmingFlowViewModel (capture anchor / disarm over the arming table)")
@MainActor
struct ArmingFlowViewModelTests {
    private static let now = Instant(nanosecondsSinceEpoch: 1_700_000_000_000_000_000)

    /// A store with a node that has a stored position fix to anchor on.
    private func seededStore(withFix: Bool = true) async throws -> MeshStore {
        let store = try MeshStore(DatabaseConnection.inMemory())
        try await store.upsertNode(NodeRecord(
            node_num: 0x07, hexid: "!00000007", short_name: "MULE",
            node_class: .mobile, first_seen_at: 0, last_heard_at: 0
        ))
        if withFix {
            _ = try await store.appendPositionFix(PositionFixRecord(
                node_num: 0x07, t: 1, lat: 37.7749, lon: -122.4194, h_accuracy: 5
            ))
        }
        return store
    }

    private func model(_ store: MeshStore) -> ArmingFlowViewModel {
        ArmingFlowViewModel(store: store, clock: InjectedClock(Self.now))
    }

    @Test
    func `capture anchors at the latest fix and arms`() async throws {
        let store = try await seededStore()
        let viewModel = model(store)
        try await viewModel.capture(nodeNum: 0x07, armed: true, thresholdMeters: 75)
        let row = try #require(viewModel.rows.first)
        #expect(row.armed)
        #expect(row.state == .anchored)
        #expect(row.thresholdMeters == 75)
        #expect(row.anchor?.lat == 37.7749)
        #expect(row.capturedAt == Self.now)
        // Persisted.
        let stored = try await store.arming(nodeNum: 0x07)
        #expect(stored?.armed == true)
        #expect(stored?.anchor_lon == -122.4194)
    }

    @Test
    func `capture refuses when not armed (safety gate)`() async throws {
        let viewModel = try await model(seededStore())
        await #expect(throws: ArmingFlowError.notArmed) {
            try await viewModel.capture(nodeNum: 0x07, armed: false)
        }
        #expect(viewModel.rows.isEmpty)
    }

    @Test
    func `capture refuses a node with no position fix`() async throws {
        let viewModel = try await model(seededStore(withFix: false))
        await #expect(throws: ArmingFlowError.noPositionFix(nodeNum: 0x07)) {
            try await viewModel.capture(nodeNum: 0x07, armed: true)
        }
    }

    @Test
    func `disarm clears the armed flag but keeps the anchor row`() async throws {
        let store = try await seededStore()
        let viewModel = model(store)
        try await viewModel.capture(nodeNum: 0x07, armed: true)
        try await viewModel.disarm(nodeNum: 0x07)
        let row = try #require(viewModel.rows.first)
        #expect(!row.armed)
        #expect(row.anchor != nil) // anchor retained for history
        let stored = try await store.arming(nodeNum: 0x07)
        #expect(stored?.armed == false)
        #expect(stored?.anchor_lat != nil)
    }

    @Test
    func `display reflects moved and returned states`() {
        let names: [Int64: String] = [0x07: "MULE"]
        let moved = ArmingRecord(
            node_num: 0x07, armed: true, threshold_m: 50,
            anchor_lat: 1, anchor_lon: 2, captured_at: 0, state: .moved
        )
        #expect(ArmingFlowViewModel.display(moved, names: names).state == .moved)
        let returned = ArmingRecord(
            node_num: 0x07, armed: true, threshold_m: 50,
            anchor_lat: 1, anchor_lon: 2, captured_at: 0, state: .returned
        )
        #expect(ArmingFlowViewModel.display(returned, names: names).state == .returned)
    }

    @Test
    func `default threshold is used when none is supplied`() async throws {
        let store = try await seededStore()
        let viewModel = model(store)
        viewModel.defaultThresholdMeters = 120
        try await viewModel.capture(nodeNum: 0x07, armed: true)
        #expect(viewModel.rows.first?.thresholdMeters == 120)
    }
}
