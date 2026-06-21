// Alert-rule CRUD over the `alert_rule` table (SPEC §2.6 / §5), backing the Phase 8
// Alerts configuration screen. Identity is (scope, scope_id, type): there is at most
// one rule per scope+type, so an upsert replaces in place. The screen edits the
// ownership-sensitive, threshold-driven rules; the daemon's RuleEngine reads the same
// table to evaluate them.

import GRDB

public extension MeshStore {
    /// Every configured alert rule across all scopes.
    func allAlertRules() async throws -> [AlertRuleRecord] {
        try await writer.read { db in try AlertRuleRecord.fetchAll(db) }
    }

    /// Insert or replace the rule identified by `(scope, scopeID, type)`.
    func upsertAlertRule(
        scope: String,
        scopeID: String?,
        type: String,
        paramsJSON: String?,
        enabled: Bool
    ) async throws {
        try await writer.write { db in
            try Self.deleteRule(db, scope: scope, scopeID: scopeID, type: type)
            var record = AlertRuleRecord(
                scope: scope, scope_id: scopeID, type: type, params_json: paramsJSON, enabled: enabled
            )
            try record.insert(db)
        }
    }

    /// Delete the rule identified by `(scope, scopeID, type)`, if present.
    func deleteAlertRule(scope: String, scopeID: String?, type: String) async throws {
        try await writer.write { db in
            try Self.deleteRule(db, scope: scope, scopeID: scopeID, type: type)
        }
    }

    /// Shared delete-by-identity, with NULL-safe `scope_id` matching.
    private static func deleteRule(_ db: Database, scope: String, scopeID: String?, type: String) throws {
        try db.execute(
            sql: """
            DELETE FROM \(AlertRuleRecord.databaseTableName)
            WHERE scope = ? AND type = ?
              AND ((? IS NULL AND scope_id IS NULL) OR scope_id = ?)
            """,
            arguments: [scope, type, scopeID, scopeID]
        )
    }
}
