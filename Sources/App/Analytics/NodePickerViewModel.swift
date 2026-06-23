// NodePickerViewModel — loads the store's nodes for the bespoke `NodePicker`, and
// orders them so the ones an operator most likely wants are surfaced first.
//
// The motivating bug: the per-node Telemetry/Analytics sections used to pin to
// `allNodes().first`, which is merely the most-recently-*heard* node — often a
// transient passer-by with no retained telemetry, so the section looked empty
// even though other nodes had plenty of data. This VM ranks nodes by a cheap
// "has data" signal (a recent position fix) ahead of bare liveness, then defaults
// the selection to the strongest candidate. It also drives a name/hex search so
// large fleets stay navigable.
//
// Data-source discipline (per the task scope): it reads ONLY existing store APIs
// — `allNodes()` for identity/liveness and the single-round-trip
// `latestPositionFixes()` for the per-node data signal. No N+1 per-node queries,
// no new store methods.
//
// @MainActor @Observable, VM-over-store; the ranking + filtering are pure and
// unit-tested over an in-memory `MeshStore`.

import Domain
import Foundation
import Observation
import Persistence

/// One selectable node in the picker: its number, display name, and `!hex` id,
/// plus the ranking signal used to order the list (a data node first).
public struct NodePickerEntry: Sendable, Equatable, Identifiable {
    public let nodeNum: Int64
    public let name: String
    public let hexID: String
    /// Newest known activity for this node (ns since epoch): the later of its
    /// last-heard time and its most-recent position fix. Drives the default sort.
    public let lastActivity: Int64
    /// Whether the node has a retained position fix — a strong "has data" hint
    /// that ranks it ahead of nodes known only by a fleeting node-info packet.
    public let hasPositionData: Bool

    public var id: Int64 {
        nodeNum
    }

    public init(nodeNum: Int64, name: String, hexID: String, lastActivity: Int64, hasPositionData: Bool) {
        self.nodeNum = nodeNum
        self.name = name
        self.hexID = hexID
        self.lastActivity = lastActivity
        self.hasPositionData = hasPositionData
    }
}

@Observable
@MainActor
public final class NodePickerViewModel {
    /// All loaded nodes, already ranked best-candidate-first.
    public private(set) var entries: [NodePickerEntry] = []
    /// The currently selected node number (`nil` until the first load resolves).
    public private(set) var selection: Int64?
    /// Whether the initial load has completed (distinguishes "empty" from "loading").
    public private(set) var loaded = false

    /// Free-text filter over name + hex id (case-insensitive). Mutating it does not
    /// touch `selection`, so a search that hides the current node still keeps it
    /// active for the content area.
    public var searchText = ""

    @ObservationIgnored private let store: MeshStore

    public init(store: MeshStore) {
        self.store = store
    }

    /// The entries matching `searchText` (all of them when the query is blank).
    public var filteredEntries: [NodePickerEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.name.lowercased().contains(query) || $0.hexID.lowercased().contains(query)
        }
    }

    /// Whether the store returned no nodes at all (a genuinely empty fleet).
    public var isEmpty: Bool {
        loaded && entries.isEmpty
    }

    /// The currently selected entry, if any.
    public var selectedEntry: NodePickerEntry? {
        entries.first { $0.nodeNum == selection }
    }

    /// Load the fleet and pick a sensible default. Reads `allNodes()` plus the
    /// batched `latestPositionFixes()` (one round-trip each), builds ranked
    /// entries, and selects the strongest candidate when nothing is selected yet.
    public func load() async throws {
        let nodes = try await store.allNodes()
        let latestFixes = try await store.latestPositionFixes()
        entries = NodePickerViewModel.rank(nodes: nodes, latestFixes: latestFixes)
        loaded = true
        if selection == nil || !entries.contains(where: { $0.nodeNum == selection }) {
            selection = entries.first?.nodeNum
        }
    }

    /// Select a node (no-op for an unknown number).
    public func select(_ nodeNum: Int64) {
        guard entries.contains(where: { $0.nodeNum == nodeNum }) else { return }
        selection = nodeNum
    }

    /// Build ranked entries from raw records: nodes with a position fix first, then
    /// by most-recent activity, with a stable hex tie-break so the order is
    /// deterministic. Pure (no store access) so it is unit-tested directly.
    public static func rank(
        nodes: [NodeRecord],
        latestFixes: [Int64: PositionFixRecord]
    ) -> [NodePickerEntry] {
        nodes
            .map { record in entry(for: record, fix: latestFixes[record.node_num]) }
            .sorted(by: isOrderedBefore)
    }

    private static func entry(for record: NodeRecord, fix: PositionFixRecord?) -> NodePickerEntry {
        let activity = max(record.last_heard_at, fix?.t ?? Int64.min)
        return NodePickerEntry(
            nodeNum: record.node_num,
            name: NetworkViewModel.displayName(record),
            hexID: NodeID.hex(UInt32(truncatingIfNeeded: record.node_num)),
            lastActivity: activity,
            hasPositionData: fix != nil
        )
    }

    /// Ordering: a node with position data outranks one without; ties break on
    /// most-recent activity, then on hex id for determinism.
    private static func isOrderedBefore(_ lhs: NodePickerEntry, _ rhs: NodePickerEntry) -> Bool {
        if lhs.hasPositionData != rhs.hasPositionData { return lhs.hasPositionData }
        if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
        return lhs.hexID < rhs.hexID
    }
}
