// ProvisioningWorkflowFactory — store-backed wiring for the provisioning workflow
// (SPEC §2.7). The single entry point the lead wires into the app shell: build a
// `ProvisioningWorkflowViewModel` whose target candidates come from the store and
// whose admin channels are resolved per the chosen `AdminAuthority`.
//
// Default channel resolution mirrors the fleet engine: a `StoreBackedAdminChannel`
// (provisions Meshtrack's record so the full flow — render→diff→confirm→apply→
// verify — is usable end-to-end). Swapping in the real `MeshAdminChannel` over the
// live transport is the remaining HIL step; the factory takes a `channelFor`
// override so that wiring is a one-liner when the radio adapter lands.

import Domain
import Foundation
import Persistence
import Provisioning

@MainActor
public enum ProvisioningWorkflowFactory {
    private typealias Candidate = ProvisioningWorkflowViewModel.TargetCandidate

    /// Build a workflow VM backed by `store`. Candidates are the store's nodes;
    /// channels default to the store-backed admin channel (override `channelFor`
    /// to send over the air via `MeshAdminChannel`).
    public static func make(
        store: MeshStore,
        draft: TemplateDraft = TemplateDraft(),
        channelFor: (@Sendable (AdminTarget) -> any AdminChannel)? = nil
    ) -> ProvisioningWorkflowViewModel {
        let resolve: @Sendable (AdminTarget) -> any AdminChannel = channelFor ?? { target in
            StoreBackedAdminChannel(store: store, nodeNum: target.nodeNum)
        }
        return ProvisioningWorkflowViewModel(
            draft: draft,
            channelFor: resolve,
            loadCandidates: { await candidates(from: store) }
        )
    }

    /// Map the store's nodes to provisioning target candidates.
    private static func candidates(from store: MeshStore) async -> [Candidate] {
        guard let nodes = try? await store.allNodes() else { return [] }
        return nodes.map { node in
            let hexID = node.hexid ?? Self.hexID(node.node_num)
            return ProvisioningWorkflowViewModel.TargetCandidate(
                nodeNum: node.node_num,
                name: node.short_name ?? node.long_name ?? hexID,
                hexID: hexID,
                shortName: node.short_name,
                longName: node.long_name,
                role: node.role,
                isNewlyDiscovered: false
            )
        }
    }

    private static func hexID(_ nodeNum: Int64) -> String {
        NodeID.hex(UInt32(truncatingIfNeeded: nodeNum))
    }
}
