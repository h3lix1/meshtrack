// NodeListViewModel — presentation logic for the node list / dashboard. Pure
// formatting + an async `load` over the store; no SwiftUI, so it is unit-tested.

import Domain
import Foundation
import Observation
import Persistence

/// A node formatted for display.
public struct NodeDisplay: Sendable, Equatable, Identifiable {
    public var id: Int64 {
        nodeNum
    }

    public let nodeNum: Int64
    public let hexID: String
    public let name: String
    public let nodeClass: NodeClass
    public let lastHeard: Instant

    public init(nodeNum: Int64, hexID: String, name: String, nodeClass: NodeClass, lastHeard: Instant) {
        self.nodeNum = nodeNum
        self.hexID = hexID
        self.name = name
        self.nodeClass = nodeClass
        self.lastHeard = lastHeard
    }
}

@Observable
@MainActor
public final class NodeListViewModel {
    public private(set) var nodes: [NodeDisplay] = []
    @ObservationIgnored private let store: MeshStore

    public init(store: MeshStore) {
        self.store = store
    }

    public func load() async throws {
        nodes = try await store.allNodes().map(Self.display)
    }

    nonisolated static func display(_ record: NodeRecord) -> NodeDisplay {
        let hex = hexID(record.node_num)
        return NodeDisplay(
            nodeNum: record.node_num,
            hexID: hex,
            name: record.short_name ?? record.long_name ?? hex,
            nodeClass: record.node_class,
            lastHeard: Instant(nanosecondsSinceEpoch: record.last_heard_at)
        )
    }

    nonisolated static func hexID(_ nodeNum: Int64) -> String {
        "!" + String(format: "%08x", UInt32(truncatingIfNeeded: nodeNum))
    }
}
