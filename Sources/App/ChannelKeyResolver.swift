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
/// falls back to the well-known default key for any channel hash the primary
/// doesn't hold — but ONLY while the default channel is present/enabled in the
/// operator's registry.
///
/// `key(forChannelHash:)` returns the primary's key when present (a custom PSK the
/// operator registered). Otherwise it returns `defaultKey` (the public Meshtastic
/// default PSK) *only if* `defaultEnabled()` reports the default channel is still
/// active; once the operator removes/clears the default channel the fallback is
/// withheld and unknown hashes resolve to `nil`, so a removed default genuinely
/// stops decoding (Finding 16). Without this gate the decoder kept handing the
/// default key to every unknown hash even after the operator deleted the default
/// channel, and an empty registry could be re-seeded as the default on next launch.
public struct ChannelKeyResolver: KeyStore {
    private let primary: any KeyStore
    private let defaultKey: ChannelKey
    private let defaultEnabled: @Sendable () -> Bool

    /// - Parameters:
    ///   - primary: the per-channel key source (Keychain channel registry in the
    ///     live app; an in-memory fake in tests). Consulted first.
    ///   - defaultKey: the fallback key for any hash the `primary` doesn't hold —
    ///     the well-known default PSK so public channels keep decoding.
    ///   - defaultEnabled: a registry-aware signal: `true` while the default channel
    ///     is present/enabled (fall back to `defaultKey`), `false` once it has been
    ///     removed/tombstoned (withhold the fallback). Defaults to always-on so the
    ///     pre-existing behavior is preserved for call sites that do not yet pass a
    ///     tombstone signal; the live path injects a registry-backed check.
    public init(
        primary: any KeyStore,
        defaultKey: ChannelKey,
        defaultEnabled: @escaping @Sendable () -> Bool = { true }
    ) {
        self.primary = primary
        self.defaultKey = defaultKey
        self.defaultEnabled = defaultEnabled
    }

    public func key(forChannelHash channelHash: UInt32) -> ChannelKey? {
        if let registered = primary.key(forChannelHash: channelHash) {
            return registered
        }
        return defaultEnabled() ? defaultKey : nil
    }
}
