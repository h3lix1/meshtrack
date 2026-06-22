// ChannelKeyResolver — resolves a `ChannelKey` for an inbound packet's channel
// hash by consulting the operator's per-channel registry FIRST, then falling back
// to the well-known default PSK.
//
// The live app lets the operator register custom-PSK channels in Channels & Keys
// (those PSKs live in the Keychain). Before this, the live ingest path keyed every
// channel with the default PSK, so any non-default channel silently failed to
// decrypt even though the settings UI implied it worked (Finding 8). This resolver
// is the fix: it composes a primary `KeyStore` (the Keychain channel registry) with
// a default fallback, so custom PSKs decode AND public default channels still work.
//
// Pure over the `Domain.KeyStore` port (no Crypto / Keychain import), so it lives in
// the snapshot-pure App library and is unit-tested headless. The executable composes
// it with the real `KeychainKeyStore` as the primary.

import Domain

/// A `KeyStore` that resolves per-channel custom PSKs from a `primary` store and
/// falls back to a fixed default key for any channel hash the primary doesn't hold.
///
/// `key(forChannelHash:)` returns the primary's key when present (a custom PSK the
/// operator registered), otherwise `defaultKey` (the public Meshtastic default PSK),
/// so the live app decodes both custom and default-keyed channels.
public struct ChannelKeyResolver: KeyStore {
    private let primary: any KeyStore
    private let defaultKey: ChannelKey

    /// - Parameters:
    ///   - primary: the per-channel key source (Keychain channel registry in the
    ///     live app; an in-memory fake in tests). Consulted first.
    ///   - defaultKey: the fallback key for any hash the `primary` doesn't hold —
    ///     the well-known default PSK so public channels keep decoding.
    public init(primary: any KeyStore, defaultKey: ChannelKey) {
        self.primary = primary
        self.defaultKey = defaultKey
    }

    public func key(forChannelHash channelHash: UInt32) -> ChannelKey? {
        primary.key(forChannelHash: channelHash) ?? defaultKey
    }
}
