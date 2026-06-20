// Persistence — GRDB (SQLite WAL) store, migration framework, schema v1
// (SPEC §5).
//
// This module is the `Store` adapter in the hexagonal architecture: the outer
// ring owns SQLite/GRDB, the Domain stays pure. Timestamps cross the boundary
// as `Domain.Instant` (Int64 nanoseconds since the Unix epoch) and are persisted
// verbatim as `INTEGER`. Secrets (channel PSKs, admin keys, MQTT creds) live in
// Keychain and are NEVER stored here (SPEC §2.5).
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
