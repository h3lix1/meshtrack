// Local, on-device `KeyStore` backed by the app's own SQLite `app_config` table —
// the replacement for the former macOS Keychain adapter.
//
// Channel PSKs here are not high-value secrets: they are the well-known Meshtastic
// default key plus whatever keys the operator types in for public channels, all of
// which are already published. So they live alongside the rest of the configuration
// in the app's local store rather than the system Keychain — simpler, no entitlement,
// and the config travels with the database.
//
// PSKs are cached in memory (Mutex-guarded) so the per-packet decode hot path never
// touches the database, and written through to the DB on every mutation so they
// survive relaunch. The whole map persists as one JSON `app_config` row keyed by
// channel hash (decimal string) → base64 PSK. Share ONE instance across the live
// decoder and the Channels & Keys screen so a freshly-added key decodes immediately.

import Domain
import Foundation
import GRDB
import Synchronization

public final class DatabaseKeyStore: KeyStore {
    /// `app_config` row key holding the JSON `{ "<hash>": "<base64 psk>" }` map.
    static let configKey = "channel_keys"

    private let writer: any DatabaseWriter
    private let cache: Mutex<[UInt32: ChannelKey]>

    public init(_ store: MeshStore) {
        writer = store.writer
        cache = Mutex(Self.loadAll(store.writer))
    }

    // MARK: - KeyStore

    public func key(forChannelHash channelHash: UInt32) -> ChannelKey? {
        cache.withLock { $0[channelHash] }
    }

    // MARK: - Store / rotate (mirrors the former KeychainKeyStore surface)

    /// Stores (or rotates) the key for `channelHash` and persists the map.
    public func store(_ key: ChannelKey, forChannelHash channelHash: UInt32) throws {
        try cache.withLock {
            $0[channelHash] = key
            try Self.persist($0, writer)
        }
    }

    /// Removes the key for `channelHash`, if present, and persists the map.
    public func removeKey(forChannelHash channelHash: UInt32) throws {
        try cache.withLock {
            $0[channelHash] = nil
            try Self.persist($0, writer)
        }
    }

    // MARK: - JSON <-> app_config

    private static func loadAll(_ writer: any DatabaseWriter) -> [UInt32: ChannelKey] {
        let json: String? = (try? writer.read { db in
            try String.fetchOne(
                db, sql: "SELECT value FROM \(Table.appConfig) WHERE key = ?", arguments: [configKey]
            )
        }) ?? nil
        guard let json, let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        var result: [UInt32: ChannelKey] = [:]
        for (hashString, base64) in raw {
            guard let hash = UInt32(hashString), let psk = Data(base64Encoded: base64) else { continue }
            result[hash] = ChannelKey(psk: [UInt8](psk))
        }
        return result
    }

    private static func persist(_ keys: [UInt32: ChannelKey], _ writer: any DatabaseWriter) throws {
        let raw = Dictionary(uniqueKeysWithValues: keys.map {
            (String($0.key), Data($0.value.psk).base64EncodedString())
        })
        guard let json = try String(bytes: JSONEncoder().encode(raw), encoding: .utf8) else {
            throw StoreError.encodingFailed(details: "channel keys JSON was not valid UTF-8")
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
