// StoreBackedAdminChannel — a live `AdminChannel` over the shared store.
//
// `currentConfig()` reports a node's known config from Meshtrack's record (the node
// row's role/short/long names + the node_config snapshot's region/position
// precision); `apply()` persists the changes back, so a rollout's read-back
// verification reflects reality and the app's fleet record stays in sync.
//
// SPEC §2.7 note: the authoritative apply is an AdminMessage over the air to the
// physical radio (local USB/BLE or remote PKI/legacy admin), which is the HIL effect
// adapter. This store-backed channel makes the full configuration engine — templates,
// targeting, diffing, safe rolling verification — usable end-to-end against
// Meshtrack's record; wiring the over-the-air transport is the remaining HIL step.

import Domain
import Persistence
import Provisioning

public struct StoreBackedAdminChannel: AdminChannel {
    private let store: MeshStore
    private let nodeNum: Int64

    public init(store: MeshStore, nodeNum: Int64) {
        self.store = store
        self.nodeNum = nodeNum
    }

    public func currentConfig() async throws -> [String: String] {
        var config: [String: String] = [:]
        if let node = try await store.fetchNode(nodeNum: nodeNum) {
            if let value = node.short_name { config["short_name"] = value }
            if let value = node.long_name { config["long_name"] = value }
            if let value = node.role { config["role"] = value }
        }
        if let nodeConfig = try await store.fetchNodeConfig(nodeNum: nodeNum) {
            if let value = nodeConfig.region { config["region"] = value }
            if let value = nodeConfig.position_precision {
                config["position_precision"] = String(value)
            }
        }
        return config
    }

    public func apply(_ changes: [ConfigChange]) async throws {
        guard !changes.isEmpty else { return }
        // Last-wins: a plan should carry one change per field, but never trap if a
        // duplicate field slips through — coalesce to the later value instead.
        let updates = Dictionary(changes.map { ($0.field, $0.to) }, uniquingKeysWith: { $1 })
        try await applyNodeFields(updates)
        try await applyNodeConfig(updates)
    }

    /// Persist role / short / long name changes to the node row.
    private func applyNodeFields(_ updates: [String: String]) async throws {
        let touchesNode = updates["short_name"] != nil || updates["long_name"] != nil || updates["role"] !=
            nil
        guard touchesNode, var node = try await store.fetchNode(nodeNum: nodeNum) else { return }
        if let value = updates["short_name"] { node.short_name = value }
        if let value = updates["long_name"] { node.long_name = value }
        if let value = updates["role"] { node.role = value }
        try await store.upsertNode(node)
    }

    /// Persist region / position-precision changes to the node_config snapshot.
    private func applyNodeConfig(_ updates: [String: String]) async throws {
        guard updates["region"] != nil || updates["position_precision"] != nil else { return }
        var snapshot = try await store.fetchNodeConfig(nodeNum: nodeNum)
            ?? NodeConfigRecord(node_num: nodeNum)
        if let value = updates["region"] { snapshot.region = value }
        if let value = updates["position_precision"] { snapshot.position_precision = Int(value) }
        try await store.saveNodeConfig(snapshot)
    }
}
