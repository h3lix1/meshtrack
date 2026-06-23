// Store-backed adapters for the live alert loop (Finding 7).
//
// `LiveAlertEvaluator` is pure over injected ports; these are the REAL adapters the
// composition root wires so live telemetry actually generates battery/stale/voltage
// alerts that the console shows. Both read the shared `MeshStore`:
//
//   • `StoreAlertSnapshotSource` builds one `NodeSnapshot` per known node — its
//     `lastHeard` from `last_heard_at`, its `batteryPercent` / `voltage` from the
//     latest `device`-kind telemetry rows (`battery_pct` / `voltage`).
//   • `StoreAlertNodeManagementLookup` snapshots `store.managedNodeNums()` so the
//     evaluator gates ownership-sensitive rules (ADR 0008) — strangers never fire
//     battery/silence alerts.
//
// In the App library (which depends on Persistence + RuleEngine) so the snapshot
// adapter is unit-tested headless against a real in-memory store.

import Domain
import Persistence
import RuleEngine

public extension StoreAlertSnapshotSource {
    /// The fallback expected-heard interval (seconds) used when a `stale` rule's
    /// threshold is 0 — a conservative day, so a zero-threshold rule never fires
    /// spuriously the instant a node is observed.
    static var defaultExpectedInterval: Double {
        86400
    }

    /// The `device`-kind telemetry keys the evaluator consumes.
    static var batteryKey: String {
        "battery_pct"
    }

    static var voltageKey: String {
        "voltage"
    }
}

/// Reads node liveness + battery/voltage from the store into `NodeSnapshot`s.
public struct StoreAlertSnapshotSource: AlertSnapshotSource {
    private let store: MeshStore

    public init(store: MeshStore) {
        self.store = store
    }

    public func snapshots() async throws -> [NodeSnapshot] {
        let nodes = try await store.allNodes()
        var result: [NodeSnapshot] = []
        result.reserveCapacity(nodes.count)
        for node in nodes {
            let telemetry = await (try? store.telemetry(forNode: node.node_num)) ?? []
            result.append(Self.snapshot(node: node, telemetry: telemetry))
        }
        return result
    }

    /// Build one snapshot from a node row + its telemetry series (latest value per
    /// key wins, since the series is ordered by time ascending). Pure + static so it
    /// is unit-testable without a store.
    static func snapshot(node: NodeRecord, telemetry: [TelemetryRecord]) -> NodeSnapshot {
        NodeSnapshot(
            nodeNum: UInt32(truncatingIfNeeded: node.node_num),
            nodeClass: node.node_class,
            lastHeard: Instant(nanosecondsSinceEpoch: node.last_heard_at),
            expectedInterval: StoreAlertSnapshotSource.defaultExpectedInterval,
            batteryPercent: latest(telemetry, key: StoreAlertSnapshotSource.batteryKey),
            voltage: latest(telemetry, key: StoreAlertSnapshotSource.voltageKey)
        )
    }

    /// The most recent finite value for `key` in a time-ascending series, or `nil`.
    private static func latest(_ telemetry: [TelemetryRecord], key: String) -> Double? {
        telemetry.last { $0.key == key && $0.value.isFinite }?.value
    }
}

/// Snapshots the store's managed-node set so the evaluator can gate ownership-
/// sensitive rules. Built per pass (a fresh lookup each `evaluate`) so it reflects
/// the latest classification without holding a stale set.
public struct StoreAlertNodeManagementLookup: AlertNodeManagementLookup {
    private let managed: Set<UInt32>

    /// Build a lookup over the currently-managed node set from the store.
    public init(store: MeshStore) async {
        let nums = await (try? store.managedNodeNums()) ?? []
        managed = Set(nums.map { UInt32(truncatingIfNeeded: $0) })
    }

    /// Direct seam for tests.
    public init(managedNodeNums: Set<UInt32>) {
        managed = managedNodeNums
    }

    public func management(forNodeNum nodeNum: UInt32) -> NodeManagement {
        managed.contains(nodeNum)
            ? NodeManagement(isMine: true, isManaged: true)
            : .unowned
    }
}
