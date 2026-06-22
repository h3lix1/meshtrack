@testable import App
import Domain
import Persistence
import RuleEngine
import Testing

@Suite("LiveAlertEvaluator (live rule-generation loop, Finding 7)")
struct LiveAlertEvaluatorTests {
    private static let now = Instant(nanosecondsSinceEpoch: 1_700_000_000_000_000_000)

    private func at(_ seconds: Double) -> Instant {
        Self.now.adding(seconds: seconds)
    }

    /// A snapshot that has been silent past the stale threshold.
    private func staleSnapshot(nodeNum: UInt32) -> NodeSnapshot {
        NodeSnapshot(
            nodeNum: nodeNum,
            nodeClass: .fixed,
            // Heard 25h ago vs a 24h stale rule → stale.
            lastHeard: at(-25 * 3600),
            expectedInterval: 3600
        )
    }

    /// An enabled global 24h stale rule (the editor authors stale in HOURS).
    private func staleRuleStore() -> InMemoryAlertRuleStore {
        InMemoryAlertRuleStore([
            AlertRuleRecord(scope: .global, type: .stale, threshold: 24, enabled: true)
        ])
    }

    private func evaluator(
        snapshots: [NodeSnapshot],
        rules: InMemoryAlertRuleStore,
        managed: Set<UInt32>,
        sink: InMemoryLiveAlertSink
    ) -> LiveAlertEvaluator {
        let lookup = FixedAlertNodeManagementLookup(
            Dictionary(uniqueKeysWithValues: managed.map { ($0, NodeManagement(isManaged: true)) })
        )
        return LiveAlertEvaluator(
            snapshots: FixedAlertSnapshotSource(snapshots),
            rules: rules,
            management: lookup,
            sink: sink,
            clock: InjectedClock(Self.now)
        )
    }

    @Test
    func `stale telemetry on a managed node produces a persisted console alert`() async throws {
        let sink = InMemoryLiveAlertSink()
        let eval = evaluator(
            snapshots: [staleSnapshot(nodeNum: 0x01)],
            rules: staleRuleStore(),
            managed: [0x01],
            sink: sink
        )
        try await eval.evaluate()

        // The alert is persisted, firing, of type stale.
        let stored = try await sink.alert(type: "stale", nodeNum: 0x01)
        let alert = try #require(stored)
        #expect(alert.state == .firing)
        #expect(alert.type == "stale")
        #expect(alert.fired_at == Self.now.nanosecondsSinceEpoch)
    }

    @Test
    func `stale telemetry on an unmanaged stranger raises no alert`() async throws {
        let sink = InMemoryLiveAlertSink()
        let eval = evaluator(
            snapshots: [staleSnapshot(nodeNum: 0x03)],
            rules: staleRuleStore(),
            managed: [], // stranger: not managed
            sink: sink
        )
        try await eval.evaluate()

        // Ownership gate (ADR 0008): nothing persisted for the stranger.
        #expect(try await sink.alert(type: "stale", nodeNum: 0x03) == nil)
        #expect(try await sink.allAlerts().isEmpty)
    }

    @Test
    func `the same node is both gated and alerted by its management`() async throws {
        // A managed node fires; an unmanaged one in the same pass does not.
        let sink = InMemoryLiveAlertSink()
        let eval = evaluator(
            snapshots: [staleSnapshot(nodeNum: 0x01), staleSnapshot(nodeNum: 0x03)],
            rules: staleRuleStore(),
            managed: [0x01],
            sink: sink
        )
        try await eval.evaluate()

        let nodes = try await sink.allAlerts().map(\.node_num).sorted()
        #expect(nodes == [0x01])
    }

    @Test
    func `a recovered node resolves its previously-firing alert`() async throws {
        // First pass: stale → firing.
        let sink = InMemoryLiveAlertSink()
        let firstPass = evaluator(
            snapshots: [staleSnapshot(nodeNum: 0x01)],
            rules: staleRuleStore(),
            managed: [0x01],
            sink: sink
        )
        try await firstPass.evaluate()
        #expect(try await sink.alert(type: "stale", nodeNum: 0x01)?.state == .firing)

        // Second pass: the node is now fresh (heard just now) → condition absent →
        // the rehydrated engine resolves it.
        let fresh = NodeSnapshot(
            nodeNum: 0x01, nodeClass: .fixed, lastHeard: Self.now, expectedInterval: 3600
        )
        let secondPass = evaluator(
            snapshots: [fresh],
            rules: staleRuleStore(),
            managed: [0x01],
            sink: sink
        )
        try await secondPass.evaluate()
        #expect(try await sink.alert(type: "stale", nodeNum: 0x01)?.state == .resolved)
    }

    @Test
    func `ruleSet converts stale hours to seconds and maps scope`() {
        let set = LiveAlertEvaluator.ruleSet(from: [
            AlertRuleRecord(scope: .global, type: .stale, threshold: 24, enabled: true),
            AlertRuleRecord(scope: .node(0x05), type: .batteryBelow, threshold: 20, enabled: true)
        ])
        let stale = set.rules.first { $0.type == .stale }
        #expect(stale?.threshold == 24.0 * 3600) // hours → seconds
        let battery = set.rules.first { $0.type == .batteryBelow }
        #expect(battery?.threshold == 20) // percent unchanged
        #expect(battery?.scope == .node(0x05))
    }
}
