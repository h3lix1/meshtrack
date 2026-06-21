@testable import App
import Domain
import Persistence
import RuleEngine
import Testing

@Suite("AlertsConsoleViewModel (console over the alert state machine)")
@MainActor
struct AlertsConsoleViewModelTests {
    private static let now = Instant(nanosecondsSinceEpoch: 1_700_000_000_000_000_000)

    private func at(_ seconds: Double) -> Instant {
        Self.now.adding(seconds: seconds)
    }

    /// A store with two managed + one unmanaged node, plus seeded alert rows.
    private func seededStore(alerts: [AlertRecord] = []) async throws -> MeshStore {
        let store = try MeshStore(DatabaseConnection.inMemory())
        try await store.upsertNode(NodeRecord(
            node_num: 0x01, hexid: "!00000001", short_name: "BASE",
            node_class: .fixed, first_seen_at: 0, last_heard_at: 0, is_managed: true
        ))
        try await store.upsertNode(NodeRecord(
            node_num: 0x02, hexid: "!00000002", short_name: "RPTR",
            node_class: .gateway, first_seen_at: 0, last_heard_at: 0, is_managed: true
        ))
        try await store.upsertNode(NodeRecord(
            node_num: 0x03, hexid: "!00000003", short_name: "STRGR",
            node_class: .mobile, first_seen_at: 0, last_heard_at: 0, is_mine: false, is_managed: false
        ))
        for alert in alerts {
            try await store.saveAlert(alert)
        }
        return store
    }

    private func model(_ store: MeshStore) -> AlertsConsoleViewModel {
        AlertsConsoleViewModel(store: store, clock: InjectedClock(Self.now))
    }

    @Test
    func `load groups alerts by state and labels nodes`() async throws {
        let store = try await seededStore(alerts: [
            AlertRecord(
                node_num: 0x01,
                type: "battery_below",
                state: .firing,
                fired_at: at(0).nanosecondsSinceEpoch
            ),
            AlertRecord(
                node_num: 0x02,
                type: "stale",
                state: .acknowledged,
                fired_at: at(-10).nanosecondsSinceEpoch,
                acked_at: at(-5).nanosecondsSinceEpoch
            )
        ])
        let viewModel = model(store)
        try await viewModel.load()
        #expect(viewModel.firing.map(\.type) == [.batteryBelow])
        #expect(viewModel.firing.first?.nodeName == "BASE")
        #expect(viewModel.acknowledged.map(\.type) == [.stale])
        #expect(viewModel.firingCount == 1)
    }

    @Test
    func `severity sort puts voltage above battery above stale`() async throws {
        let store = try await seededStore(alerts: [
            AlertRecord(node_num: 0x01, type: "stale", state: .firing, fired_at: at(0).nanosecondsSinceEpoch),
            AlertRecord(
                node_num: 0x01,
                type: "battery_below",
                state: .firing,
                fired_at: at(0).nanosecondsSinceEpoch
            ),
            AlertRecord(
                node_num: 0x02,
                type: "voltage_below",
                state: .firing,
                fired_at: at(0).nanosecondsSinceEpoch
            )
        ])
        let viewModel = model(store)
        try await viewModel.load()
        #expect(viewModel.firing.map(\.type) == [.voltageBelow, .batteryBelow, .stale])
    }

    @Test
    func `recency sort orders by fired time newest-first`() async throws {
        let store = try await seededStore(alerts: [
            AlertRecord(
                node_num: 0x01,
                type: "stale",
                state: .firing,
                fired_at: at(-100).nanosecondsSinceEpoch
            ),
            AlertRecord(
                node_num: 0x02,
                type: "voltage_below",
                state: .firing,
                fired_at: at(-50).nanosecondsSinceEpoch
            )
        ])
        let viewModel = model(store)
        viewModel.sort = .recency
        try await viewModel.load()
        // Newest (voltage at -50) first despite lower-... actually higher severity;
        // recency ignores severity → voltage(-50) before stale(-100).
        #expect(viewModel.firing.map(\.nodeNum) == [0x02, 0x01])
    }

    @Test
    func `filter by node narrows the visible alerts`() async throws {
        let store = try await seededStore(alerts: [
            AlertRecord(
                node_num: 0x01,
                type: "battery_below",
                state: .firing,
                fired_at: at(0).nanosecondsSinceEpoch
            ),
            AlertRecord(node_num: 0x02, type: "stale", state: .firing, fired_at: at(0).nanosecondsSinceEpoch)
        ])
        let viewModel = model(store)
        try await viewModel.load()
        #expect(viewModel.firing.count == 2)
        viewModel.nodeFilter = 0x01
        #expect(viewModel.firing.map(\.nodeNum) == [0x01])
    }

    @Test
    func `filter by type narrows the visible alerts`() async throws {
        let store = try await seededStore(alerts: [
            AlertRecord(
                node_num: 0x01,
                type: "battery_below",
                state: .firing,
                fired_at: at(0).nanosecondsSinceEpoch
            ),
            AlertRecord(node_num: 0x02, type: "stale", state: .firing, fired_at: at(0).nanosecondsSinceEpoch)
        ])
        let viewModel = model(store)
        try await viewModel.load()
        viewModel.typeFilter = .stale
        #expect(viewModel.firing.map(\.type) == [.stale])
    }

    @Test
    func `acknowledge moves a firing alert to acknowledged and persists`() async throws {
        let store = try await seededStore(alerts: [
            AlertRecord(
                node_num: 0x01,
                type: "battery_below",
                state: .firing,
                fired_at: at(0).nanosecondsSinceEpoch
            )
        ])
        let viewModel = model(store)
        try await viewModel.load()
        let item = try #require(viewModel.firing.first)
        try await viewModel.acknowledge(item)
        #expect(viewModel.firing.isEmpty)
        #expect(viewModel.acknowledged.map(\.type) == [.batteryBelow])
        // Persisted: the stored row is now acknowledged.
        let stored = try await store.alert(type: "battery_below", nodeNum: 0x01)
        #expect(stored?.state == .acknowledged)
        #expect(stored?.acked_at != nil)
    }

    @Test
    func `resolve moves an alert to resolved and persists the timestamp`() async throws {
        let store = try await seededStore(alerts: [
            AlertRecord(node_num: 0x01, type: "stale", state: .firing, fired_at: at(0).nanosecondsSinceEpoch)
        ])
        let viewModel = model(store)
        try await viewModel.load()
        let item = try #require(viewModel.firing.first)
        try await viewModel.resolve(item)
        #expect(viewModel.firing.isEmpty)
        #expect(viewModel.resolved.map(\.type) == [.stale])
        let stored = try await store.alert(type: "stale", nodeNum: 0x01)
        #expect(stored?.state == .resolved)
        #expect(stored?.resolved_at != nil)
    }

    @Test
    func `snooze records remaining time and persists`() async throws {
        let store = try await seededStore(alerts: [
            AlertRecord(
                node_num: 0x01,
                type: "battery_below",
                state: .firing,
                fired_at: at(0).nanosecondsSinceEpoch
            )
        ])
        let viewModel = model(store)
        try await viewModel.load()
        let item = try #require(viewModel.firing.first)
        try await viewModel.snooze(item, forSeconds: 600)
        let snoozed = try #require(viewModel.firing.first)
        #expect(snoozed.snoozeRemaining.map { abs($0 - 600) < 0.001 } == true)
        // Reload from store → snooze survives the round-trip via payload_json.
        let reloaded = model(store)
        try await reloaded.load()
        #expect(reloaded.firing.first?.snoozeRemaining.map { $0 > 0 } == true)
    }

    @Test
    func `suppressed surface lists unmanaged nodes with an explainer`() async throws {
        let viewModel = try await model(seededStore())
        try await viewModel.load()
        #expect(viewModel.suppressedNodes.map(\.nodeNum) == [0x03])
        #expect(viewModel.suppressedNodes.first?.reason.contains("unmanaged") == true)
    }

    @Test
    func `cooldownRemaining counts down only for resolved alerts within cooldown`() {
        let remaining = AlertsConsoleViewModel.cooldownRemaining(
            state: .resolved, cooldownSeconds: 300, resolvedAt: Self.now, now: at(100)
        )
        #expect(remaining.map { abs($0 - 200) < 0.001 } == true)
        // After the window, nil.
        #expect(AlertsConsoleViewModel.cooldownRemaining(
            state: .resolved, cooldownSeconds: 300, resolvedAt: Self.now, now: at(400)
        ) == nil)
        // A firing alert has no cooldown.
        #expect(AlertsConsoleViewModel.cooldownRemaining(
            state: .firing, cooldownSeconds: 300, resolvedAt: Self.now, now: at(1)
        ) == nil)
    }

    @Test
    func `snoozeRemaining is positive within the window and nil after`() {
        #expect(AlertsConsoleViewModel.snoozeRemaining(snoozedUntil: at(600), now: Self.now)
            .map { abs($0 - 600) < 0.001 } == true)
        #expect(AlertsConsoleViewModel.snoozeRemaining(snoozedUntil: at(600), now: at(700)) == nil)
        #expect(AlertsConsoleViewModel.snoozeRemaining(snoozedUntil: nil, now: Self.now) == nil)
    }
}
