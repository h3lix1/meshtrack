// InMemoryChannelKeyManager — the test/preview backing for the Channels & Keys
// screen's `ChannelKeyManaging` port. Split out of `ChannelsSettingsViewModel`
// so the production view-model file stays focused on presentation logic; the live
// path is the lead's Keychain-backed adapter, not this fake.

import Domain

/// In-memory `ChannelKeyManaging` for tests and the preview. Holds channel
/// metadata and PSK bytes in process memory only — no Keychain, no logging. The
/// production path is the lead's `KeychainKeyStore` adapter.
///
/// Implemented as an `actor` so its mutable state is isolated without locks and it
/// satisfies the `async` `ChannelKeyManaging` port directly.
public actor InMemoryChannelKeyManager: ChannelKeyManaging {
    private var order: [UInt32] = []
    private var entries: [UInt32: (name: String, kind: ChannelKind)] = [:]
    private var keysByHash: [UInt32: ChannelKey] = [:]

    public init() {}

    public func channels() -> [ChannelEntry] {
        order.compactMap { hash in
            guard let meta = entries[hash] else { return nil }
            return ChannelEntry(
                name: meta.name,
                hash: hash,
                kind: meta.kind,
                hasKey: keysByHash[hash] != nil
            )
        }
    }

    public func addChannel(name: String, hash: UInt32, kind: ChannelKind) {
        if entries[hash] == nil {
            order.append(hash)
        }
        entries[hash] = (name, kind)
    }

    public func removeChannel(hash: UInt32) {
        entries[hash] = nil
        keysByHash[hash] = nil
        order.removeAll { $0 == hash }
    }

    public func hasKey(forChannelHash hash: UInt32) -> Bool {
        keysByHash[hash] != nil
    }

    public func setKey(_ key: ChannelKey, forChannelHash hash: UInt32) {
        keysByHash[hash] = key
    }

    public func clearKey(forChannelHash hash: UInt32) {
        keysByHash[hash] = nil
    }

    /// Test-only inspection of the stored PSK, to assert the plaintext round-trips
    /// to the *store* even though it never returns to the UI.
    public func storedKey(forChannelHash hash: UInt32) -> ChannelKey? {
        keysByHash[hash]
    }
}
