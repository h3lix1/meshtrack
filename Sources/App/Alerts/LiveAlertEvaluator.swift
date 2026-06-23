// LiveAlertEvaluator — the live rule-generation loop (Finding 7, SPEC §2.6).
//
// The phase-7 review flagged that alert rules are configurable but nothing in the
// running app evaluates telemetry/liveness through `RuleEvaluator → AlertEngine`
// and persists the results: the console only rehydrates/mutates persisted rows.
// This coordinator closes that gap.
//
// It is a testable coordinator over INJECTED ports — a snapshot source (node
// liveness/telemetry), the configured `AlertRuleStore`, and a node-management
// classification lookup — plus the pure `RuleEvaluator` and the `AlertEngine`
// state machine. One pass:
//
//   1. load the current node snapshots + the effective rule set;
//   2. for each node, resolve ownership and run `RuleEvaluator.conditions` —
//      ownership-sensitive rules (stale / battery / voltage) only fire for
//      MANAGED nodes, so a low-battery stranger never raises a console alert
//      (ADR 0008);
//   3. rehydrate the engine from persisted alerts so existing lifecycle + cooldown
//      survive, reconcile the live conditions, and persist the resulting alerts.
//
// Every port ships a fake (see `LiveAlertEvaluatorFakes`). The real wiring — the
// store-backed snapshot source / management lookup and the scheduling cadence —
// is an injection seam the lead composes; this type takes only its ports.

import Domain
import Persistence
import RuleEngine

/// Supplies the node snapshots to evaluate (liveness + battery/voltage). The real
/// adapter reads them from the store; tests inject a fixed set.
public protocol AlertSnapshotSource: Sendable {
    /// One snapshot per node currently worth evaluating, at the source's `now`.
    func snapshots() async throws -> [NodeSnapshot]
}

/// Resolves a node's ownership classification so the evaluator can gate
/// ownership-sensitive rules (ADR 0008). App-layer port (the App target does not
/// depend on Scenario); the lead adapts the store's managed set to it.
public protocol AlertNodeManagementLookup: Sendable {
    /// The ownership classification for `nodeNum`. Unknown nodes resolve to
    /// unmanaged — never battery/silence-alerted.
    func management(forNodeNum nodeNum: UInt32) -> NodeManagement
}

/// The persistence seam the evaluator writes through. Satisfied by `MeshStore`
/// (via the `AlertsStore` extension); a fake records writes in tests.
public protocol LiveAlertSink: Sendable {
    /// Every persisted alert row (for rehydrating the engine before reconcile).
    func allAlerts() async throws -> [AlertRecord]
    /// The current row for a (type, node), if tracked.
    func alert(type: String, nodeNum: Int64) async throws -> AlertRecord?
    /// Insert or update an alert row.
    func saveAlert(_ alert: AlertRecord) async throws -> Int64
}

/// `MeshStore` already provides exactly this surface (see `AlertsStore.swift`), so
/// the production adapter is the store itself.
extension MeshStore: LiveAlertSink {}

public struct LiveAlertEvaluator: Sendable {
    private let snapshots: any AlertSnapshotSource
    private let rules: any AlertRuleStore
    private let management: any AlertNodeManagementLookup
    private let sink: any LiveAlertSink
    private let clock: any Clock

    public init(
        snapshots: any AlertSnapshotSource,
        rules: any AlertRuleStore,
        management: any AlertNodeManagementLookup,
        sink: any LiveAlertSink,
        clock: any Clock
    ) {
        self.snapshots = snapshots
        self.rules = rules
        self.management = management
        self.sink = sink
        self.clock = clock
    }

    /// Run one evaluation pass: read snapshots + rules, evaluate every node through
    /// `RuleEvaluator`, reconcile through a rehydrated `AlertEngine`, and persist
    /// the resulting alert rows. Returns the alerts that are currently active after
    /// the pass (firing / acknowledged / resolved) so callers can react/log.
    @discardableResult
    public func evaluate() async throws -> [Alert] {
        let now = clock.now()
        let nodeSnapshots = try await snapshots.snapshots()
        let ruleSet = try await Self.ruleSet(from: rules.allRules())

        // Build the conditions that currently hold across every node. Ownership is
        // resolved per node so RuleEvaluator gates stranger nodes (ADR 0008).
        var conditions: [AlertCondition] = []
        for snapshot in nodeSnapshots {
            conditions.append(contentsOf: RuleEvaluator.conditions(
                for: snapshot,
                rules: ruleSet,
                now: now,
                management: management.management(forNodeNum: snapshot.nodeNum)
            ))
        }

        // Rehydrate the engine from the persisted rows so an existing alert's
        // lifecycle + cooldown survive this pass (no spurious re-fire), then
        // reconcile the live conditions against them.
        var engine = try await AlertsConsoleViewModel.rehydrate(sink.allAlerts())
        engine.reconcile(conditions, now: now)

        // Persist every tracked alert back to the store.
        for alert in engine.alerts {
            try await persist(alert)
        }
        return engine.alerts
    }

    // MARK: Rule conversion

    /// Translate the configured `AlertRuleStore` records (the editor's units — %, V,
    /// HOURS) into the `RuleEngine.RuleSet` the evaluator consumes (stale in
    /// SECONDS). Disabled records are dropped at the `RuleSet` boundary too, but we
    /// carry `enabled` so the engine's own filter stays authoritative.
    static func ruleSet(from records: [AlertRuleRecord]) -> RuleSet {
        RuleSet(records.compactMap(rule(from:)))
    }

    private static func rule(from record: AlertRuleRecord) -> AlertRule? {
        guard let type = engineType(record.type) else { return nil }
        return AlertRule(
            type: type,
            scope: scope(record.scope),
            threshold: threshold(record.threshold, for: record.type),
            enabled: record.enabled
        )
    }

    /// Stale thresholds are authored in hours but evaluated in seconds; battery (%)
    /// and voltage (V) are already in the engine's units.
    private static func threshold(_ value: Double, for type: AlertRuleType) -> Double {
        switch type {
        case .stale: value * 3600
        case .batteryBelow, .voltageBelow: value
        }
    }

    private static func engineType(_ type: AlertRuleType) -> AlertType? {
        switch type {
        case .stale: .stale
        case .batteryBelow: .batteryBelow
        case .voltageBelow: .voltageBelow
        }
    }

    private static func scope(_ scope: AlertRuleScope) -> RuleScope {
        switch scope {
        case .global: .global
        case let .nodeClass(nodeClass): .nodeClass(nodeClass)
        case let .node(num): .node(num)
        }
    }

    // MARK: Persistence

    /// Upsert one engine `Alert` onto its persisted row, preserving the existing
    /// `id` / `rule_id` and carrying detail + cooldown through `payload_json` (so a
    /// later reload keeps the cooldown — Finding 13).
    private func persist(_ alert: Alert) async throws {
        let nodeNum = Int64(alert.nodeNum)
        let existing = try await sink.alert(type: alert.type.rawValue, nodeNum: nodeNum)
        let record = AlertRecord(
            id: existing?.id,
            rule_id: existing?.rule_id,
            node_num: nodeNum,
            type: alert.type.rawValue,
            state: alert.state,
            fired_at: alert.firedAt.nanosecondsSinceEpoch,
            acked_at: alert.ackedAt?.nanosecondsSinceEpoch,
            resolved_at: alert.resolvedAt?.nanosecondsSinceEpoch,
            payload_json: AlertsConsoleViewModel.payload(
                detail: alert.detail,
                snoozedUntil: alert.snoozedUntil,
                cooldownSeconds: alert.cooldownSeconds
            )
        )
        _ = try await sink.saveAlert(record)
    }
}
