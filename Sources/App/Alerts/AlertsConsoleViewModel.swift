// AlertsConsoleViewModel — presentation logic for the alerts console (G5, SPEC
// §2.6 / ADR 0008).
//
// A testable `@MainActor @Observable` view model over an in-memory `MeshStore`,
// driving a bespoke console view (snapshot fidelity). It folds the persisted
// `alert` rows into a held `AlertEngine` state machine so ack / snooze / resolve
// go through the *same* lifecycle the live collector uses, then writes the result
// back to the store — a true round-trip, never a UI-local mutation.
//
// Surfaces:
//  - alerts grouped by state (firing / acknowledged / resolved);
//  - sort by severity then recency; filter by node and by type;
//  - cooldown-remaining (until a resolved alert may re-fire) and snooze-remaining;
//  - managed-aware suppression: which node types never raise battery/stale alerts,
//    and which observed nodes are suppressed *right now*, so a quiet low-battery
//    stranger node is explained, not mysterious (ADR 0008).

import Domain
import Foundation
import Observation
import Persistence
import RuleEngine

/// One alert formatted for the console. Carries the live engine `Alert` plus the
/// derived, time-relative facts the view renders (cooldown / snooze remaining).
public struct AlertConsoleItem: Sendable, Equatable, Identifiable {
    public var id: String {
        "\(type.rawValue)#\(nodeNum)"
    }

    public let type: AlertType
    public let nodeNum: Int64
    public let nodeName: String
    public let detail: String
    public let state: AlertState
    public let firedAt: Instant
    /// Seconds until a *resolved* alert is eligible to re-fire (cooldown), or nil
    /// when not resolved / no cooldown pending.
    public let cooldownRemaining: Double?
    /// Seconds until an active snooze expires, or nil when not snoozed.
    public let snoozeRemaining: Double?

    /// Higher = more urgent. Drives the default sort and the row tint.
    public var severity: Int {
        AlertSeverity.rank(type)
    }

    public init(
        type: AlertType,
        nodeNum: Int64,
        nodeName: String,
        detail: String,
        state: AlertState,
        firedAt: Instant,
        cooldownRemaining: Double? = nil,
        snoozeRemaining: Double? = nil
    ) {
        self.type = type
        self.nodeNum = nodeNum
        self.nodeName = nodeName
        self.detail = detail
        self.state = state
        self.firedAt = firedAt
        self.cooldownRemaining = cooldownRemaining
        self.snoozeRemaining = snoozeRemaining
    }
}

@Observable
@MainActor
public final class AlertsConsoleViewModel {
    /// Items grouped by lifecycle state, sorted per `sort`. Read by the view.
    public private(set) var firing: [AlertConsoleItem] = []
    public private(set) var acknowledged: [AlertConsoleItem] = []
    public private(set) var resolved: [AlertConsoleItem] = []

    /// Managed-aware suppression surface: nodes currently observed that won't raise
    /// battery/stale alerts because they're unmanaged (ADR 0008). Empty when every
    /// observed node is managed.
    public private(set) var suppressedNodes: [SuppressedNode] = []

    /// Active filters. Setting either re-derives the grouped lists from the last
    /// load (no store round-trip needed).
    public var nodeFilter: Int64? {
        didSet { regroup() }
    }

    public var typeFilter: AlertType? {
        didSet { regroup() }
    }

    public var sort: AlertSort = .severity {
        didSet { regroup() }
    }

    /// Whether anything is currently firing (drives the nav badge).
    public var firingCount: Int {
        firing.count
    }

    @ObservationIgnored private let store: MeshStore
    @ObservationIgnored private let clock: Clock
    /// The lifecycle state machine, rehydrated from the persisted rows on `load`.
    @ObservationIgnored private var engine = AlertEngine()
    /// The full, unfiltered set from the last load — `regroup` filters from this.
    @ObservationIgnored private var allItems: [AlertConsoleItem] = []
    /// node_num → display name, captured at load for relabeling derived items.
    @ObservationIgnored private var nodeNames: [Int64: String] = [:]

    public init(store: MeshStore, clock: Clock) {
        self.store = store
        self.clock = clock
    }

    // MARK: Load

    /// Load alerts + the suppression surface from the store and rehydrate the
    /// engine so ack/snooze/resolve operate on real lifecycle state.
    public func load() async throws {
        let records = try await store.allAlerts()
        let nodes = try await store.allNodes()
        nodeNames = Dictionary(
            nodes.map { ($0.node_num, Self.name(for: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
        engine = Self.rehydrate(records)
        suppressedNodes = Self.deriveSuppressed(nodes)
        rebuildItems()
    }

    // MARK: Actions (round-trip through engine + store)

    /// Acknowledge a firing alert: advance the state machine and persist the new
    /// `acked_at` / state onto the row.
    public func acknowledge(_ item: AlertConsoleItem) async throws {
        let now = clock.now()
        engine.acknowledge(type: item.type, nodeNum: UInt32(truncatingIfNeeded: item.nodeNum), at: now)
        try await persist(type: item.type, nodeNum: item.nodeNum)
        rebuildItems()
    }

    /// Snooze an alert for `seconds`: silences re-announcements until it expires.
    public func snooze(_ item: AlertConsoleItem, forSeconds seconds: Double) async throws {
        let until = clock.now().adding(seconds: seconds)
        engine.snooze(type: item.type, nodeNum: UInt32(truncatingIfNeeded: item.nodeNum), until: until)
        try await persist(type: item.type, nodeNum: item.nodeNum)
        rebuildItems()
    }

    /// Manually resolve an alert (operator cleared it). Reconciles the engine with
    /// this condition absent so the lifecycle marks it resolved at `now`.
    public func resolve(_ item: AlertConsoleItem) async throws {
        let now = clock.now()
        // Reconcile with every *other* condition still present; the omitted one
        // resolves. Build the present set from the current non-resolved items.
        let remaining = engine.alerts
            .filter { $0.state != .resolved && $0.key != item.engineKey }
            .map(Self.condition)
        engine.reconcile(remaining, now: now)
        try await persist(type: item.type, nodeNum: item.nodeNum)
        rebuildItems()
    }

    // MARK: Derivation

    private func rebuildItems() {
        let now = clock.now()
        allItems = engine.alerts.map { Self.item($0, now: now, names: nodeNames) }
        regroup()
    }

    private func regroup() {
        let filtered = allItems.filter { item in
            (nodeFilter == nil || item.nodeNum == nodeFilter)
                && (typeFilter == nil || item.type == typeFilter)
        }
        let sorted = filtered.sorted(by: ordering)
        firing = sorted.filter { $0.state == .firing }
        acknowledged = sorted.filter { $0.state == .acknowledged }
        resolved = sorted.filter { $0.state == .resolved }
    }

    private func ordering(_ lhs: AlertConsoleItem, _ rhs: AlertConsoleItem) -> Bool {
        switch sort {
        case .severity:
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            if lhs.firedAt != rhs.firedAt { return lhs.firedAt > rhs.firedAt }
            return tieBreak(lhs, rhs)
        case .recency:
            if lhs.firedAt != rhs.firedAt { return lhs.firedAt > rhs.firedAt }
            return tieBreak(lhs, rhs)
        }
    }

    /// Stable, total tie-break so equal-priority alerts have a deterministic order
    /// (important: `engine.alerts` iterates a dictionary, which is unordered).
    private func tieBreak(_ lhs: AlertConsoleItem, _ rhs: AlertConsoleItem) -> Bool {
        lhs.id < rhs.id
    }

    private func persist(type: AlertType, nodeNum: Int64) async throws {
        guard let alert = engine.alert(type: type, nodeNum: UInt32(truncatingIfNeeded: nodeNum))
        else { return }
        let existing = try await store.alert(type: type.rawValue, nodeNum: nodeNum)
        let record = AlertRecord(
            id: existing?.id,
            rule_id: existing?.rule_id,
            node_num: nodeNum,
            type: type.rawValue,
            state: alert.state,
            fired_at: alert.firedAt.nanosecondsSinceEpoch,
            acked_at: alert.ackedAt?.nanosecondsSinceEpoch,
            resolved_at: alert.resolvedAt?.nanosecondsSinceEpoch,
            payload_json: Self.payload(detail: alert.detail, snoozedUntil: alert.snoozedUntil)
        )
        try await store.saveAlert(record)
    }

    // MARK: Pure mapping (testable without a store)

    /// Rebuild the engine from persisted rows so the console resumes the lifecycle
    /// after an app restart.
    static func rehydrate(_ records: [AlertRecord]) -> AlertEngine {
        var engine = AlertEngine()
        // Fire each row at its OWN fired_at (oldest first) so the rehydrated alert
        // keeps its real fired time — the console sorts on it. Reconciling all at
        // once would collapse every firedAt to a single `now`. `historical` so a
        // reload never re-announces a stored alert (storm-safe).
        let ordered = records.sorted { $0.fired_at < $1.fired_at }
        var present: [AlertCondition] = []
        for record in ordered {
            present.append(AlertCondition(
                type: AlertType(rawValue: record.type) ?? .stale,
                nodeNum: UInt32(truncatingIfNeeded: record.node_num),
                detail: detail(from: record.payload_json),
                cooldownSeconds: 0
            ))
            engine.reconcile(present, now: Instant(nanosecondsSinceEpoch: record.fired_at), historical: true)
        }
        // Apply each row's terminal state + timestamps.
        for record in records {
            let type = AlertType(rawValue: record.type) ?? .stale
            let nodeNum = UInt32(truncatingIfNeeded: record.node_num)
            switch record.state {
            case .acknowledged:
                if let acked = record.acked_at {
                    engine.acknowledge(
                        type: type,
                        nodeNum: nodeNum,
                        at: Instant(nanosecondsSinceEpoch: acked)
                    )
                }
            case .resolved:
                // Resolve by reconciling this condition absent.
                let others = engine.alerts
                    .filter { $0.state != .resolved && !($0.type == type && $0.nodeNum == nodeNum) }
                    .map(condition)
                let at = record.resolved_at ?? record.fired_at
                engine.reconcile(others, now: Instant(nanosecondsSinceEpoch: at), historical: true)
            case .firing:
                break
            }
            if let until = snoozedUntil(from: record.payload_json) {
                engine.snooze(type: type, nodeNum: nodeNum, until: until)
            }
        }
        return engine
    }

    static func item(_ alert: Alert, now: Instant, names: [Int64: String]) -> AlertConsoleItem {
        let nodeNum = Int64(alert.nodeNum)
        return AlertConsoleItem(
            type: alert.type,
            nodeNum: nodeNum,
            nodeName: names[nodeNum] ?? hexID(nodeNum),
            detail: alert.detail,
            state: alert.state,
            firedAt: alert.firedAt,
            cooldownRemaining: cooldownRemaining(
                state: alert.state, cooldownSeconds: alert.cooldownSeconds,
                resolvedAt: alert.resolvedAt ?? alert.firedAt, now: now
            ),
            snoozeRemaining: snoozeRemaining(snoozedUntil: alert.snoozedUntil, now: now)
        )
    }

    /// Seconds until a resolved alert may re-fire; nil when not resolved or done.
    /// Pure over scalars so it's testable without the engine's internal `Alert`.
    static func cooldownRemaining(
        state: AlertState,
        cooldownSeconds: Double,
        resolvedAt: Instant,
        now: Instant
    ) -> Double? {
        guard state == .resolved, cooldownSeconds > 0 else { return nil }
        let remaining = cooldownSeconds - now.secondsSince(resolvedAt)
        return remaining > 0 ? remaining : nil
    }

    /// Seconds until an active snooze expires; nil when not snoozed or expired.
    static func snoozeRemaining(snoozedUntil: Instant?, now: Instant) -> Double? {
        guard let until = snoozedUntil, until > now else { return nil }
        return until.secondsSince(now)
    }

    /// Nodes that are observed but won't raise ownership-sensitive alerts because
    /// they're unmanaged (ADR 0008). Sorted by name for a stable surface.
    static func deriveSuppressed(_ nodes: [NodeRecord]) -> [SuppressedNode] {
        nodes
            .filter { !$0.is_managed }
            .map { node in
                let why = node.is_mine
                    ? "mine but unmanaged — battery/stale alerts off"
                    : "unmanaged stranger — battery/stale alerts off"
                return SuppressedNode(nodeNum: node.node_num, nodeName: name(for: node), reason: why)
            }
            .sorted { $0.nodeName < $1.nodeName }
    }

    // MARK: Helpers

    private static func condition(_ alert: Alert) -> AlertCondition {
        AlertCondition(
            type: alert.type, nodeNum: alert.nodeNum, detail: alert.detail,
            cooldownSeconds: alert.cooldownSeconds
        )
    }

    private static func name(for node: NodeRecord) -> String {
        node.short_name ?? node.long_name ?? hexID(node.node_num)
    }

    static func hexID(_ nodeNum: Int64) -> String {
        "!" + String(format: "%08x", UInt32(truncatingIfNeeded: nodeNum))
    }

    /// Tiny JSON payload carrying the detail string + snooze; avoids a new column.
    private static func payload(detail: String, snoozedUntil: Instant?) -> String? {
        var dict: [String: String] = ["detail": detail]
        if let until = snoozedUntil { dict["snoozed_until"] = String(until.nanosecondsSinceEpoch) }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }

    private static func detail(from payload: String?) -> String {
        decode(payload)?["detail"] ?? ""
    }

    private static func snoozedUntil(from payload: String?) -> Instant? {
        guard let raw = decode(payload)?["snoozed_until"], let nanos = Int64(raw) else { return nil }
        return Instant(nanosecondsSinceEpoch: nanos)
    }

    private static func decode(_ payload: String?) -> [String: String]? {
        guard let payload, let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }
        return object
    }
}

private extension AlertConsoleItem {
    var engineKey: AlertKey {
        AlertKey(type: type, nodeNum: UInt32(truncatingIfNeeded: nodeNum))
    }
}
