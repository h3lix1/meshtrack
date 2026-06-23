// Fakes for the LiveAlertEvaluator ports (every effect ships a fake, per
// AGENTS.md). These back previews/tests; the lead wires the store-backed adapters
// at integration.

import Domain
import Persistence
import RuleEngine

/// A fixed set of node snapshots, returned as-is each pass. The harness-friendly
/// snapshot source for driving the evaluator without a store.
public struct FixedAlertSnapshotSource: AlertSnapshotSource {
    private let fixed: [NodeSnapshot]

    public init(_ snapshots: [NodeSnapshot]) {
        fixed = snapshots
    }

    public func snapshots() async throws -> [NodeSnapshot] {
        fixed
    }
}

/// An explicit node → management map; nodes absent from the map resolve to
/// unmanaged (so a stranger never raises ownership-sensitive alerts).
public struct FixedAlertNodeManagementLookup: AlertNodeManagementLookup {
    private let byNodeNum: [UInt32: NodeManagement]
    private let fallback: NodeManagement

    public init(_ byNodeNum: [UInt32: NodeManagement], fallback: NodeManagement = .unowned) {
        self.byNodeNum = byNodeNum
        self.fallback = fallback
    }

    public func management(forNodeNum nodeNum: UInt32) -> NodeManagement {
        byNodeNum[nodeNum] ?? fallback
    }
}

/// An in-memory `LiveAlertSink` that records every persisted alert, keyed by
/// (type, node) so a save replaces in place — exactly like the store's upsert. The
/// recorded rows are what tests assert against.
public actor InMemoryLiveAlertSink: LiveAlertSink {
    private var rows: [String: AlertRecord] = [:]
    private var nextID: Int64 = 1

    public init(_ seed: [AlertRecord] = []) {
        var counter: Int64 = 1
        for record in seed {
            var stored = record
            if let id = record.id {
                stored.id = id
            } else {
                stored.id = counter
                counter += 1
            }
            rows[Self.key(type: record.type, nodeNum: record.node_num)] = stored
        }
        nextID = counter
    }

    /// Every recorded alert (the console feed shape).
    public func allAlerts() async throws -> [AlertRecord] {
        Array(rows.values)
    }

    public func alert(type: String, nodeNum: Int64) async throws -> AlertRecord? {
        rows[Self.key(type: type, nodeNum: nodeNum)]
    }

    @discardableResult
    public func saveAlert(_ alert: AlertRecord) async throws -> Int64 {
        upsert(alert)
    }

    @discardableResult
    private func upsert(_ alert: AlertRecord) -> Int64 {
        var record = alert
        let key = Self.key(type: alert.type, nodeNum: alert.node_num)
        let id = rows[key]?.id ?? alert.id ?? assignID()
        record.id = id
        rows[key] = record
        return id
    }

    private func assignID() -> Int64 {
        defer { nextID += 1 }
        return nextID
    }

    private static func key(type: String, nodeNum: Int64) -> String {
        "\(type)#\(nodeNum)"
    }
}
