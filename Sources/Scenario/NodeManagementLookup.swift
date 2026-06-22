// NodeManagementLookup — the ownership-resolution port for the liveness alert
// path (ADR 0008, SPEC §2.10).
//
// `RuleEvaluator` gates ownership-sensitive rules (`stale` / `battery_below` /
// `voltage_below`) on a node's `NodeManagement`, but it can't *find* that flag —
// it's pure. This port is how the evaluator resolves, per node, whether the node
// is managed, so the gate is driven by the node's REAL classification instead of
// a hardcoded "managed" default. Implementations:
//
//   - ``ManagedFleetLookup`` — every node managed (single-fleet / legacy default).
//   - ``FixedNodeManagementLookup`` — an explicit node → management map (tests).
//   - ``StoreNodeManagementLookup`` — resolves `is_managed` from the live
//     ``MeshStore`` (the production adapter).

import Domain
import Persistence

/// Resolves a node's ownership classification (ADR 0008). Pure and synchronous so
/// the deterministic ``LivenessScenarioEvaluator`` can call it inline; async stores
/// pre-resolve into ``StoreNodeManagementLookup`` before evaluation.
public protocol NodeManagementLookup: Sendable {
    /// The ownership classification for `nodeNum`. Unknown nodes resolve to
    /// ``NodeManagement/unowned`` (unmanaged — never battery/silence-alerted).
    func management(forNodeNum nodeNum: UInt32) -> NodeManagement
}

/// Treats every node as managed. The single-fleet default, preserving the
/// behaviour of callers that don't (yet) classify their nodes.
public struct ManagedFleetLookup: NodeManagementLookup {
    public init() {}

    public func management(forNodeNum _: UInt32) -> NodeManagement {
        NodeManagement(isManaged: true)
    }
}

/// An explicit node → management map; nodes absent from the map are
/// ``NodeManagement/unowned`` (unmanaged). The fake used to drive ownership
/// scenarios in tests without a store.
public struct FixedNodeManagementLookup: NodeManagementLookup {
    private let byNodeNum: [UInt32: NodeManagement]
    private let fallback: NodeManagement

    /// - Parameters:
    ///   - byNodeNum: explicit classifications keyed by node number.
    ///   - fallback: management for nodes not in the map (default: unmanaged).
    public init(
        _ byNodeNum: [UInt32: NodeManagement],
        fallback: NodeManagement = .unowned
    ) {
        self.byNodeNum = byNodeNum
        self.fallback = fallback
    }

    public func management(forNodeNum nodeNum: UInt32) -> NodeManagement {
        byNodeNum[nodeNum] ?? fallback
    }
}

/// The production adapter: resolves `is_managed` from the live ``MeshStore``.
///
/// The store API is async; the evaluator is synchronous, so callers pre-resolve
/// the managed set with ``load(from:)`` once before evaluation. Nodes not in the
/// managed set are treated as unmanaged — exactly ADR 0008's read-only stance for
/// strangers' nodes.
public struct StoreNodeManagementLookup: NodeManagementLookup {
    private let managedNodeNums: Set<UInt32>

    /// Build directly from a known managed set (e.g. in tests).
    public init(managedNodeNums: Set<UInt32>) {
        self.managedNodeNums = managedNodeNums
    }

    /// Snapshot the store's managed node set so the synchronous evaluator can
    /// resolve ownership without awaiting. Call once per evaluation pass.
    public static func load(from store: MeshStore) async throws -> StoreNodeManagementLookup {
        let nums = try await store.managedNodeNums()
        return StoreNodeManagementLookup(
            managedNodeNums: Set(nums.map { UInt32(truncatingIfNeeded: $0) })
        )
    }

    public func management(forNodeNum nodeNum: UInt32) -> NodeManagement {
        NodeManagement(isManaged: managedNodeNums.contains(nodeNum))
    }
}
