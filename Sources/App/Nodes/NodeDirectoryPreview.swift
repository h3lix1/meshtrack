// NodeDirectoryPreview — sample data for the directory `#Preview` (Phase 7 G3).
//
// Builds a small in-memory store seeded with a mix of roles + ownership flags so
// the directory preview shows role tabs, the My-Nodes filter, and the
// managed/unmanaged split with real content. Preview-only; never used in the live
// app (the lead supplies the live store). The seed is async + throwing (mirrors
// `AnalyticsPreviewData`) so there is no force-unwrap at the call site.

import Persistence

/// Sample-data factory for the node directory preview.
public enum NodeDirectoryPreview {
    /// A fixed sample fleet: roles, ownership flags, and a couple of strangers'
    /// nodes (unmanaged) to exercise the segmentation. `ownership` is
    /// (`isMine`, `isManaged`).
    public static let nodes: [NodeRecord] = [
        node(0xA1B2_C3D4, "BASE", role: "ROUTER", ownership: (true, true), heard: 9000),
        node(0x0000_0F01, "RPTR", role: "REPEATER", ownership: (true, true), heard: 8000),
        node(0x0000_0C02, "TRK1", role: "TRACKER", ownership: (true, false), heard: 7000),
        node(0x0000_0C03, "PHON", role: "CLIENT", ownership: (true, false), heard: 6000),
        node(0x0000_0E04, "STR1", role: "CLIENT", ownership: (false, false), heard: 5000),
        node(0x0000_0E05, "STR2", role: "ROUTER", ownership: (false, false), heard: 4000)
    ]

    /// A fresh in-memory store seeded with `nodes`.
    public static func seededStore() async throws -> MeshStore {
        let store = try MeshStore(DatabaseConnection.inMemory())
        for record in nodes {
            try await store.upsertNode(record)
        }
        return store
    }

    private static func node(
        _ num: Int64,
        _ shortName: String,
        role: String,
        ownership: (isMine: Bool, isManaged: Bool),
        heard: Int64
    ) -> NodeRecord {
        NodeRecord(
            node_num: num,
            short_name: shortName,
            node_class: role == "ROUTER" ? .gateway : .mobile,
            role: role,
            first_seen_at: 0,
            last_heard_at: heard,
            is_mine: ownership.isMine,
            is_managed: ownership.isManaged
        )
    }
}
