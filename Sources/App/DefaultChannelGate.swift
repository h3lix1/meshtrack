// DefaultChannelGate — the synchronously-readable "is the public default channel
// still active?" signal that gates default-PSK fallback decoding (Finding 16).
//
// `ChannelKeyResolver.defaultEnabled` is a SYNC `@Sendable () -> Bool` consulted per
// inbound packet (the decoder is hot and synchronous), but the source of truth — the
// `app_config` channel registry + the "default removed" tombstone — is async. This
// gate bridges that: a `Mutex`-protected `Bool` the decoder reads synchronously,
// refreshed from the store (the slow refresh loop at startup, and immediately when
// the operator removes the default in Channels & Keys).
//
// The decode decision itself is pure (`DefaultChannelDecodePolicy`): fall back to the
// default key only while the default channel is present in the registry AND has not
// been tombstoned. So removing the default genuinely stops default-key decoding this
// session (the gate is refreshed) AND across relaunch (the tombstone persists).

import Synchronization

/// The pure decode decision for the default-PSK fallback.
public enum DefaultChannelDecodePolicy {
    /// Whether the live decoder should fall back to the public default PSK for an
    /// unknown channel hash.
    ///
    /// - Parameters:
    ///   - registryContainsDefault: the default-MediumFast channel is present in the
    ///     operator's registry.
    ///   - tombstoned: the operator removed the default channel (a persisted
    ///     "default removed" marker is set).
    /// - Returns: `true` only when the default is present AND not tombstoned.
    public static func defaultEnabled(
        registryContainsDefault: Bool,
        tombstoned: Bool
    ) -> Bool {
        registryContainsDefault && !tombstoned
    }
}

/// A `Sendable`, synchronously-readable boolean gate for the default-PSK fallback.
/// Defaults to enabled so the public channel decodes out of the box until a refresh
/// (or a removal) says otherwise.
public final class DefaultChannelGate: Sendable {
    private let enabled: Mutex<Bool>

    public init(enabled: Bool = true) {
        self.enabled = Mutex(enabled)
    }

    /// Read the current gate value (the decoder's per-packet check).
    public func isEnabled() -> Bool {
        enabled.withLock { $0 }
    }

    /// Replace the gate value (called after a store refresh / a default removal).
    public func set(_ value: Bool) {
        enabled.withLock { $0 = value }
    }
}
