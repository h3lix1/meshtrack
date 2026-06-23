// Fleet configuration storage (SPEC §2.7): persisted provisioning templates and the
// per-node config snapshot the fleet engine diffs against. Templates are reusable and
// editable in the app; the node_config snapshot is Meshtrack's record of a node's
// applied config (region/position precision), complementing the node-table name/role.

import GRDB

public extension MeshStore {
    // MARK: Templates

    /// All saved provisioning templates, ordered by name.
    func allTemplates() async throws -> [TemplateRecord] {
        try await writer.read { db in
            try TemplateRecord.order(Column("name")).fetchAll(db)
        }
    }

    /// Insert (when `id` is nil) or update a template; returns its row id.
    @discardableResult
    func upsertTemplate(_ template: TemplateRecord) async throws -> Int64 {
        try await writer.write { db in
            var record = template
            try record.save(db)
            return record.id ?? db.lastInsertedRowID
        }
    }

    /// Delete the template with `id`, if present.
    func deleteTemplate(id: Int64) async throws {
        try await writer.write { db in
            _ = try TemplateRecord.deleteOne(db, key: id)
        }
    }

    // MARK: Per-node config snapshot

    /// The stored config snapshot for a node, or `nil` if none.
    func fetchNodeConfig(nodeNum: Int64) async throws -> NodeConfigRecord? {
        try await writer.read { db in
            try NodeConfigRecord.fetchOne(db, key: nodeNum)
        }
    }

    /// Insert or replace a node's config snapshot.
    func saveNodeConfig(_ config: NodeConfigRecord) async throws {
        try await writer.write { db in
            try config.save(db)
        }
    }
}
