// NodeDirectoryViewModel — the CoreScope-style node directory (Phase 7 G3).
//
// A testable `@MainActor @Observable` view model over the store that drives a
// filterable, searchable node directory with ownership classification:
//
//   * Role tabs — filter by the node's mesh role / class (router, client,
//     repeater, tracker, gateway …) derived from `NodeRecord.role` / `node_class`.
//   * Text search — matches the node's name or hex id (case-insensitive).
//   * "My Nodes" toggle — narrows to `is_mine` nodes (ADR 0008 visibility flag).
//   * Managed / unmanaged segmentation — `is_managed` partitions the visible set;
//     counts are exposed per segment so the UI can label "12 managed · 4 observed".
//   * Bulk-classify — a multi-selection of node_nums flushed to the store via the
//     bulk `setOwnership(nodeNums:isMine:isManaged:)` helper (ADR 0008).
//   * Drill-through — `selectedNodeNum` is the seam the lead links to G4's
//     `NodeAnalyticsView` / the node detail.
//
// All filtering/search/segmentation is pure over an in-memory cache of
// `NodeDirectoryEntry`, so the behaviour is fully unit-tested; only `load()` and
// the bulk-classify write touch the async store.

import Domain
import Foundation
import Observation
import Persistence

/// One node formatted for the directory: identity, ownership flags, and the role
/// used for tab filtering.
public struct NodeDirectoryEntry: Sendable, Equatable, Identifiable {
    public var id: Int64 {
        nodeNum
    }

    public let nodeNum: Int64
    public let hexID: String
    public let name: String
    public let nodeClass: NodeClass
    /// The mesh role tab this entry belongs to (router/client/repeater/…),
    /// inferred from `NodeRecord.role` with a `node_class` fallback.
    public let role: NodeRole
    public let isMine: Bool
    public let isManaged: Bool
    public let lastHeard: Instant

    public init(
        nodeNum: Int64,
        hexID: String,
        name: String,
        nodeClass: NodeClass,
        role: NodeRole,
        isMine: Bool,
        isManaged: Bool,
        lastHeard: Instant
    ) {
        self.nodeNum = nodeNum
        self.hexID = hexID
        self.name = name
        self.nodeClass = nodeClass
        self.role = role
        self.isMine = isMine
        self.isManaged = isManaged
        self.lastHeard = lastHeard
    }
}

/// The mesh role a node plays — the directory's role-tab dimension. Mirrors the
/// firmware `Config.DeviceConfig.Role` names we ingest into `NodeRecord.role`,
/// collapsed to the buckets an operator filters by.
public enum NodeRole: String, Sendable, CaseIterable, Identifiable {
    case client
    case router
    case repeater
    case tracker
    case sensor
    case gateway
    case other

    public var id: String {
        rawValue
    }

    /// A short human label for the role tab.
    public var label: String {
        switch self {
        case .client: "Client"
        case .router: "Router"
        case .repeater: "Repeater"
        case .tracker: "Tracker"
        case .sensor: "Sensor"
        case .gateway: "Gateway"
        case .other: "Other"
        }
    }

    /// Infer the role from the raw firmware role string (if any) and the node's
    /// class. Unknown / absent roles fall back to the class (gateway → `.gateway`)
    /// and finally `.other`.
    public static func infer(role: String?, nodeClass: NodeClass) -> NodeRole {
        if let role {
            let upper = role.uppercased()
            if upper.contains("REPEATER") {
                return .repeater
            }
            if upper.contains("ROUTER") {
                return .router
            }
            if upper.contains("TRACKER") {
                return .tracker
            }
            if upper.contains("SENSOR") {
                return .sensor
            }
            if upper.contains("CLIENT") {
                return .client
            }
        }
        if nodeClass == .gateway {
            return .gateway
        }
        return .other
    }
}

/// The role filter: a specific role, or "all roles".
public enum RoleFilter: Hashable, Sendable, Identifiable {
    case all
    case role(NodeRole)

    public var id: String {
        switch self {
        case .all: "all"
        case let .role(role): role.rawValue
        }
    }

    public var label: String {
        switch self {
        case .all: "All"
        case let .role(role): role.label
        }
    }
}

/// The ownership segment a node falls into for the managed/unmanaged split.
public enum OwnershipSegment: String, Sendable, CaseIterable, Identifiable {
    /// `is_managed == true` — ownership-sensitive rules apply (ADR 0008).
    case managed
    /// `is_managed == false` — observed read-only, no battery/stale alerts.
    case unmanaged

    public var id: String {
        rawValue
    }

    public var label: String {
        switch self {
        case .managed: "Managed"
        case .unmanaged: "Observed"
        }
    }
}

@Observable
@MainActor
public final class NodeDirectoryViewModel {
    // MARK: Filter state (drives the derived `visible` list)

    /// The active role tab.
    public var roleFilter: RoleFilter = .all {
        didSet { recompute() }
    }

    /// Case-insensitive search over name + hex id.
    public var searchText: String = "" {
        didSet { recompute() }
    }

    /// Whether the "My Nodes" filter is on (`is_mine` only).
    public var myNodesOnly: Bool = false {
        didSet { recompute() }
    }

    // MARK: Multi-select (bulk-classify)

    /// The node_nums currently selected for bulk classification.
    public private(set) var selection: Set<Int64> = []

    /// The node the operator drilled into (detail / analytics seam). `nil` when
    /// nothing is selected for inspection.
    public var selectedNodeNum: Int64?

    // MARK: Derived outputs

    /// Every node, formatted, most-recently-heard first (the unfiltered cache).
    public private(set) var allEntries: [NodeDirectoryEntry] = []

    /// The entries passing the active role / search / my-nodes filters,
    /// most-recently-heard first.
    public private(set) var visible: [NodeDirectoryEntry] = []

    @ObservationIgnored private let store: MeshStore

    public init(store: MeshStore) {
        self.store = store
    }

    // MARK: Loading

    /// Load every node from the store and recompute the filtered view.
    public func load() async throws {
        allEntries = try await store.allNodes().map(Self.entry)
        recompute()
    }

    // MARK: Counts (per segment / overall)

    /// Total nodes known (unfiltered).
    public var totalCount: Int {
        allEntries.count
    }

    /// Nodes flagged `is_mine` (unfiltered) — the "My Nodes" badge count.
    public var myNodesCount: Int {
        allEntries.lazy.filter(\.isMine).count
    }

    /// Count of the currently-visible entries in `segment`.
    public func count(in segment: OwnershipSegment) -> Int {
        entries(in: segment).count
    }

    /// Number of available role tabs that actually have at least one node,
    /// excluding the catch-all `.all` — used to hide empty tabs if desired.
    public var presentRoles: [NodeRole] {
        var seen = Set<NodeRole>()
        for entry in allEntries where !seen.contains(entry.role) {
            seen.insert(entry.role)
        }
        return NodeRole.allCases.filter { seen.contains($0) }
    }

    /// The visible entries belonging to `segment` (managed vs unmanaged), in the
    /// same most-recently-heard order.
    public func entries(in segment: OwnershipSegment) -> [NodeDirectoryEntry] {
        switch segment {
        case .managed: visible.filter(\.isManaged)
        case .unmanaged: visible.filter { !$0.isManaged }
        }
    }

    // MARK: Selection / bulk-classify

    /// Toggle a node's membership in the bulk-classify selection.
    public func toggleSelection(_ nodeNum: Int64) {
        if selection.contains(nodeNum) {
            selection.remove(nodeNum)
        } else {
            selection.insert(nodeNum)
        }
    }

    /// Whether `nodeNum` is in the current selection.
    public func isSelected(_ nodeNum: Int64) -> Bool {
        selection.contains(nodeNum)
    }

    /// Select every currently-visible node (bulk-select-all over the filtered set).
    public func selectAllVisible() {
        selection = Set(visible.map(\.nodeNum))
    }

    /// Clear the bulk-classify selection.
    public func clearSelection() {
        selection.removeAll()
    }

    /// Apply ownership flags to the current selection and refresh. Passing `nil`
    /// for a flag leaves it unchanged (so "mark managed" never disturbs "mine").
    /// Returns the number of nodes actually updated. The selection is cleared on
    /// success.
    @discardableResult
    public func classifySelection(isMine: Bool? = nil, isManaged: Bool? = nil) async throws -> Int {
        guard !selection.isEmpty else {
            return 0
        }
        let nodeNums = Array(selection)
        let updated = try await store.setOwnership(nodeNums: nodeNums, isMine: isMine, isManaged: isManaged)
        // Reflect the change in the cache + clear the selection without a full
        // round-trip; `load()` would also work but this keeps the UI snappy.
        applyLocally(nodeNums: Set(nodeNums), isMine: isMine, isManaged: isManaged)
        clearSelection()
        recompute()
        return updated
    }

    // MARK: Recompute (pure)

    private func recompute() {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        visible = allEntries.filter { entry in
            Self.matches(entry, role: roleFilter, needle: needle, myNodesOnly: myNodesOnly)
        }
    }

    /// Whether `entry` passes every active filter. Pure & static so it is directly
    /// unit-testable.
    nonisolated static func matches(
        _ entry: NodeDirectoryEntry,
        role: RoleFilter,
        needle: String,
        myNodesOnly: Bool
    ) -> Bool {
        if myNodesOnly, !entry.isMine {
            return false
        }
        if case let .role(wanted) = role, entry.role != wanted {
            return false
        }
        if !needle.isEmpty {
            let inName = entry.name.lowercased().contains(needle)
            let inHex = entry.hexID.lowercased().contains(needle)
            if !inName, !inHex {
                return false
            }
        }
        return true
    }

    private func applyLocally(nodeNums: Set<Int64>, isMine: Bool?, isManaged: Bool?) {
        allEntries = allEntries.map { entry in
            guard nodeNums.contains(entry.nodeNum) else {
                return entry
            }
            return NodeDirectoryEntry(
                nodeNum: entry.nodeNum,
                hexID: entry.hexID,
                name: entry.name,
                nodeClass: entry.nodeClass,
                role: entry.role,
                isMine: isMine ?? entry.isMine,
                isManaged: isManaged ?? entry.isManaged,
                lastHeard: entry.lastHeard
            )
        }
    }

    // MARK: Formatting (pure)

    /// Format a node record into a directory entry.
    nonisolated static func entry(_ record: NodeRecord) -> NodeDirectoryEntry {
        let hex = hexID(record.node_num)
        return NodeDirectoryEntry(
            nodeNum: record.node_num,
            hexID: hex,
            name: record.short_name ?? record.long_name ?? hex,
            nodeClass: record.node_class,
            role: NodeRole.infer(role: record.role, nodeClass: record.node_class),
            isMine: record.is_mine,
            isManaged: record.is_managed,
            lastHeard: Instant(nanosecondsSinceEpoch: record.last_heard_at)
        )
    }

    /// The `!aabbccdd` hex id for a node number.
    nonisolated static func hexID(_ nodeNum: Int64) -> String {
        "!" + String(format: "%08x", UInt32(truncatingIfNeeded: nodeNum))
    }
}
