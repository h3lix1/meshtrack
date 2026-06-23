// Generic key-value access over the `app_config` table (Phase 8). Used for small
// app state that doesn't warrant its own table — e.g. the channel registry
// (names/hashes/kinds; the PSKs themselves are kept by `DatabaseKeyStore`, also in
// `app_config`). The typed `ConfigGateway` (broker / app settings) uses its own
// reserved keys; callers here must pick distinct keys.

import GRDB

public extension MeshStore {
    /// The stored string for `key`, or `nil` if unset.
    func appConfigValue(forKey key: String) async throws -> String? {
        try await writer.read { db in
            try String.fetchOne(
                db, sql: "SELECT value FROM \(Table.appConfig) WHERE key = ?", arguments: [key]
            )
        }
    }

    /// Upsert `value` for `key`; a `nil` value deletes the row.
    func setAppConfigValue(_ value: String?, forKey key: String) async throws {
        try await writer.write { db in
            if let value {
                try db.execute(
                    sql: """
                    INSERT INTO \(Table.appConfig)(key, value) VALUES(?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                    arguments: [key, value]
                )
            } else {
                try db.execute(sql: "DELETE FROM \(Table.appConfig) WHERE key = ?", arguments: [key])
            }
        }
    }
}
