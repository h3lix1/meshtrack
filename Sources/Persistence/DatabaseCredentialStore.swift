// Local, on-device `CredentialStore` backed by the app's own SQLite `app_config`
// table — the replacement for the former macOS Keychain adapter.
//
// The only credential stored is the MQTT broker password. For the public brokers
// this app targets that password is already well known (it is published alongside
// the broker), so it lives with the rest of the configuration in the local store
// rather than the system Keychain. It is still never logged.
//
// Passwords are cached in memory (Mutex-guarded) and written through to the DB on
// every change so they survive relaunch. The whole map persists as one JSON
// `app_config` row keyed by `"host|username"` so multiple brokers/accounts coexist.

import Domain
import Foundation
import GRDB
import Synchronization

public final class DatabaseCredentialStore: CredentialStore {
    /// `app_config` row key holding the JSON `{ "<host|username>": "<password>" }` map.
    static let configKey = "broker_credentials"

    private let writer: any DatabaseWriter
    private let cache: Mutex<[String: String]>

    public init(_ store: MeshStore) {
        writer = store.writer
        cache = Mutex(Self.loadAll(store.writer))
    }

    // MARK: - CredentialStore

    public func password(host: String, username: String?) -> String? {
        cache.withLock { $0[Self.account(host: host, username: username)] }
    }

    /// Stores, rotates, or (with a nil/empty password) clears the broker password
    /// for `host` + `username`, persisting the map.
    public func setPassword(_ password: String?, host: String, username: String?) throws {
        let account = Self.account(host: host, username: username)
        try cache.withLock {
            if let password, !password.isEmpty {
                $0[account] = password
            } else {
                $0[account] = nil
            }
            try Self.persist($0, writer)
        }
    }

    // MARK: - Helpers

    /// The stable account string for a broker account: `"host|username"` (empty
    /// username segment when anonymous), so anonymous and named brokers on the same
    /// host stay distinct. Pure and side-effect-free.
    static func account(host: String, username: String?) -> String {
        "\(host)|\(username ?? "")"
    }

    // MARK: - JSON <-> app_config

    private static func loadAll(_ writer: any DatabaseWriter) -> [String: String] {
        let json: String? = (try? writer.read { db in
            try String.fetchOne(
                db, sql: "SELECT value FROM \(Table.appConfig) WHERE key = ?", arguments: [configKey]
            )
        }) ?? nil
        guard let json, let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return raw
    }

    private static func persist(_ credentials: [String: String], _ writer: any DatabaseWriter) throws {
        guard let json = try String(bytes: JSONEncoder().encode(credentials), encoding: .utf8) else {
            throw StoreError.encodingFailed(details: "broker credentials JSON was not valid UTF-8")
        }
        try writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO \(Table.appConfig)(key, value) VALUES(?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [configKey, json]
            )
        }
    }
}
