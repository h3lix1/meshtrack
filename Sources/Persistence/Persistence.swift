// Persistence — GRDB (SQLite WAL) store, migration framework, schema v1
// (SPEC §5).
//
// This module is the `Store` adapter in the hexagonal architecture: the outer
// ring owns SQLite/GRDB, the Domain stays pure. Timestamps cross the boundary
// as `Domain.Instant` (Int64 nanoseconds since the Unix epoch) and are persisted
// verbatim as `INTEGER`. The already-public channel PSKs and MQTT password are kept
// locally in the `app_config` table (`DatabaseKeyStore` / `DatabaseCredentialStore`),
// not the system Keychain; they are never logged.
//
// Public surface:
//   - `MeshStore`             — the actor-safe store API later phases use.
//   - `DatabaseConnection`    — opens SQLite in WAL mode (file or in-memory).
//   - `MeshtrackMigrator`     — the `DatabaseMigrator` carrying schema v1.
//   - record structs in `Records.swift`, schema names in `Schema.swift`.

/// Module marker retained for the linkability smoke test and tooling.
public enum PersistenceModule {
    public static let name = "Persistence"
}
