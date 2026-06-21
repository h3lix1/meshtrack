// Node ownership: "mine" & managed vs unmanaged (SPEC §2.10, ADR 0008).
//
// Two orthogonal, descriptive flags. They never alter ingestion or dedup; they
// change *visibility* (`isMine` → the "My Nodes" filter) and *alerting
// eligibility* (`isManaged` → ownership-sensitive rules). Pure value type so the
// rule engine can gate evaluation without touching Persistence.

/// The ownership classification of a node.
public struct NodeManagement: Hashable, Sendable {
    /// Part of the operator's fleet. Drives the "My Nodes" filter; affects
    /// visibility only.
    public let isMine: Bool
    /// We administer the node (own its battery / hold an admin key).
    /// **Ownership-sensitive rules evaluate only when this is true** (ADR 0008).
    public let isManaged: Bool

    public init(isMine: Bool = false, isManaged: Bool = false) {
        self.isMine = isMine
        self.isManaged = isManaged
    }

    /// Neither mine nor managed — the default for a freshly-observed stranger's
    /// node (no false battery/silence alerts).
    public static let unowned = NodeManagement(isMine: false, isManaged: false)
}

public extension NodeManagement {
    /// Whether ownership-sensitive rules (`battery_below`, `voltage_below`,
    /// `stale`) are eligible to evaluate for a node with this management. Movement,
    /// geofence, and `new_node_seen` are global and ignore this gate.
    var evaluatesOwnershipRules: Bool {
        isManaged
    }
}
