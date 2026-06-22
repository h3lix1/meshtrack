// NodeAdminCommand — the imperative, non-config admin commands (SPEC §2.7).
//
// Most admin traffic is config diffs (region/role/…), which flow through
// `ConfigChange` → `AdminMessageMapping.messages` → the begin/commit transaction.
// A handful of admin operations are NOT config: they target ANOTHER node by its
// node-num and the firmware applies them immediately, outside any edit transaction
// — favouriting/unfavouriting a node (so it's pinned in the node DB and exempt from
// eviction) and ignoring/unignoring one (so its traffic is dropped). This type
// carries those through the same admin path as a single, self-contained message.
//
// Pure & `Sendable` so it can cross the `AdminCommandChannel` actor boundary; the
// message construction is `AdminMessageMapping.message(for:)`.

import Foundation

/// An imperative admin command targeting a node by its node-num. Unlike a config
/// change, these are applied immediately by the firmware (no begin/commit) and are
/// idempotent on the node side.
public enum NodeAdminCommand: Sendable, Equatable {
    /// Pin `nodeNum` as a favourite (`setFavoriteNode`) — exempt from DB eviction.
    case favorite(nodeNum: UInt32)
    /// Clear `nodeNum`'s favourite flag (`removeFavoriteNode`).
    case unfavorite(nodeNum: UInt32)
    /// Ignore `nodeNum` (`setIgnoredNode`) — its traffic is dropped on receipt.
    case ignore(nodeNum: UInt32)
    /// Clear `nodeNum`'s ignored flag (`removeIgnoredNode`).
    case unignore(nodeNum: UInt32)

    /// The node this command acts on.
    public var nodeNum: UInt32 {
        switch self {
        case let .favorite(nodeNum),
             let .unfavorite(nodeNum),
             let .ignore(nodeNum),
             let .unignore(nodeNum):
            nodeNum
        }
    }

    /// A short label for UI/logging.
    public var label: String {
        switch self {
        case .favorite: "Favorite"
        case .unfavorite: "Unfavorite"
        case .ignore: "Ignore"
        case .unignore: "Unignore"
        }
    }
}
