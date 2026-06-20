// In-memory `KeyStore` fake (SPEC §2.5). Used by unit tests and the replay
// pipeline, where there is no Keychain (or we do not want to touch it). Keys
// live only in process memory and are never persisted.

import Domain
import Synchronization

/// A thread-safe, in-memory `Domain.KeyStore`.
///
/// This is the fake that ships alongside the real `KeychainKeyStore` adapter
/// (every effect ships a fake, per AGENTS.md). It is the store used in the unit
/// tests, since Keychain access is unavailable in headless/CI runs.
///
/// State is guarded by a `Mutex` (from `Synchronization`, which is part of the
/// toolchain — no Foundation), so the type is `Sendable` and safe to share
/// across the ingestion actors.
public final class InMemoryKeyStore: KeyStore {
    private let keysByChannelHash: Mutex<[UInt32: ChannelKey]>

    /// Creates a store optionally seeded with `keys`, keyed by channel hash.
    public init(keys: [UInt32: ChannelKey] = [:]) {
        keysByChannelHash = Mutex(keys)
    }

    public func key(forChannelHash channelHash: UInt32) -> ChannelKey? {
        keysByChannelHash.withLock { $0[channelHash] }
    }

    /// Stores (or rotates) the key for `channelHash`, replacing any existing one.
    public func store(_ key: ChannelKey, forChannelHash channelHash: UInt32) {
        keysByChannelHash.withLock { $0[channelHash] = key }
    }

    /// Removes the key for `channelHash`, if present.
    public func removeKey(forChannelHash channelHash: UInt32) {
        keysByChannelHash.withLock { $0[channelHash] = nil }
    }
}
