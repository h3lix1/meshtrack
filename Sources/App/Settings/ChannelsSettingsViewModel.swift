// ChannelsSettingsViewModel — the Channels & Keys settings screen's presentation
// logic (Phase 8, T-Channels). Manages the operator's MQTT + local channels and
// their PSKs (SPEC §2.5: PSKs are secrets → Keychain; §10: up to 20 MQTT / 7 local).
//
// The PSK bytes themselves never live in this view model and are never echoed back
// as plaintext after entry — they flow straight through the `ChannelKeyManaging`
// port into the Keychain, and the UI only ever sees a "key set / no key" flag.
//
// This file owns its own port (`ChannelKeyManaging`) so the App library does not
// depend on `Crypto`: the lead adapts the real `KeychainKeyStore` to it at
// integration. An in-file `InMemoryChannelKeyManager` backs tests and the preview.

import Domain
import Foundation
import Observation

/// Whether a channel is carried over the MQTT broker or the locally-attached node.
/// The local device firmware caps at 7 channels (SPEC §10); MQTT is broker-side and
/// effectively unbounded — the operator may subscribe to as many channels as they
/// hold keys for, so it carries no UI cap.
public enum ChannelKind: String, Sendable, Equatable, CaseIterable, Codable {
    case mqtt
    case local

    /// The maximum number of channels of this kind the config allows. The local
    /// radio firmware is hard-capped at 7; MQTT is effectively unlimited
    /// (`Int.max`), so its section shows a plain count rather than an "X / N" cap.
    public var capacity: Int {
        switch self {
        case .mqtt: .max
        case .local: 7
        }
    }

    /// Whether this kind enforces a finite, user-visible capacity. MQTT does not.
    public var hasFiniteCapacity: Bool {
        capacity != .max
    }

    public var title: String {
        switch self {
        case .mqtt: "MQTT Channels"
        case .local: "Local Channels"
        }
    }
}

/// One channel as shown in the settings list. Non-secret: it carries the channel's
/// name, its Meshtastic channel hash (`MeshPacket.channel`), its kind, and only a
/// *flag* for whether a PSK is held — never the PSK bytes.
public struct ChannelEntry: Sendable, Equatable, Identifiable {
    public var id: UInt32 {
        hash
    }

    public let name: String
    public let hash: UInt32
    public let kind: ChannelKind
    /// True when a PSK is held in the Keychain for this channel. Drives the
    /// "key set" vs "no key" status; the plaintext is never surfaced.
    public let hasKey: Bool

    public init(name: String, hash: UInt32, kind: ChannelKind, hasKey: Bool) {
        self.name = name
        self.hash = hash
        self.kind = kind
        self.hasKey = hasKey
    }
}

/// Port: read/list/set/delete a `ChannelKey` per channel, plus the list of known
/// channels. Kept in the App layer (not Crypto) so the library's dependency graph
/// stays `Domain`/`Persistence`/`RuleEngine`/`Provisioning` only; the lead adapts
/// the real `KeychainKeyStore` (which already has `store`/`removeKey`/`key`) plus a
/// channel registry to this protocol at integration.
///
/// Secrets contract (SPEC §2.5): implementations persist PSKs in the Keychain only,
/// never the DB, and never log them. The view model passes `ChannelKey` straight
/// through and never retains it.
/// All methods are `async` so the port can be backed by the Keychain and an
/// asynchronous channel registry (`app_config`) without blocking the `@MainActor`
/// view model — the previous synchronous shape is exactly what kept this tab
/// from being wired to the real `KeychainKeyStore`.
public protocol ChannelKeyManaging: Sendable {
    /// Every channel the operator has configured, in stable order.
    func channels() async throws -> [ChannelEntry]
    /// Register (or replace) a channel by `name`/`hash`/`kind`. Does not set a key.
    func addChannel(name: String, hash: UInt32, kind: ChannelKind) async throws
    /// Remove a channel and any key held for it.
    func removeChannel(hash: UInt32) async throws
    /// Whether a PSK is currently held for `hash`.
    func hasKey(forChannelHash hash: UInt32) async -> Bool
    /// Store or rotate the PSK for `hash`. Throws to surface a precise failure
    /// without ever including the secret bytes.
    func setKey(_ key: ChannelKey, forChannelHash hash: UInt32) async throws
    /// Remove the PSK for `hash`, leaving the channel registered but keyless.
    func clearKey(forChannelHash hash: UInt32) async throws
}

/// Typed failures surfaced to the UI. None of these carry secret material.
public enum ChannelsSettingsError: Error, Equatable, Sendable {
    /// The kind is already at its SPEC §10 capacity (20 MQTT / 7 local).
    case capacityReached(ChannelKind)
    /// The channel name was empty after trimming.
    case emptyName
    /// A channel with the derived hash already exists.
    case duplicateChannel
    /// The supplied PSK text was not valid base64 / a known shortcut.
    case invalidKey
    /// The underlying key store failed (e.g. Keychain error). Carries a redacted
    /// description only — never the secret.
    case storeFailed(String)
}

/// Channel-key math: deriving the Meshtastic channel hash and parsing PSK text.
/// Pure and `nonisolated` so it can be unit-tested without the `@MainActor` VM.
public enum ChannelKeyMath {
    /// The well-known Meshtastic default channel key — PSK index `1`, written
    /// `"AQ=="` in base64 (a single `0x01` byte expands to these 16 bytes). Shared
    /// by the public LongFast/MediumFast channels (SPEC §1, §10).
    public static let defaultPSK: [UInt8] = [
        0xD4, 0xF1, 0xBB, 0x3A, 0x20, 0x29, 0x07, 0x59,
        0xF0, 0xBC, 0xFF, 0xAB, 0xCF, 0x4E, 0x69, 0x01
    ]

    /// The Meshtastic `MeshPacket.channel` hash: XOR of every byte of the channel
    /// name with every byte of the PSK, as a single byte widened to `UInt32`
    /// (matches the firmware's `generateHash`). The default channel ("" name with
    /// the index-1 key) hashes the same way the radios do, so traffic decodes.
    public static func channelHash(name: String, psk: [UInt8]) -> UInt32 {
        var hash: UInt8 = 0
        for byte in name.utf8 {
            hash ^= byte
        }
        for byte in psk {
            hash ^= byte
        }
        return UInt32(hash)
    }

    /// Parse user-entered PSK text into raw bytes. Accepts the Meshtastic
    /// default-key shortcut `"AQ=="` (→ the 16-byte default key) and otherwise
    /// base64 that decodes to a valid AES key size (16 or 32 bytes). Empty text
    /// is rejected; use `clearKey` to remove a key instead.
    public static func parsePSK(_ text: String) throws -> [UInt8] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ChannelsSettingsError.invalidKey
        }
        if trimmed == "AQ==" {
            return defaultPSK
        }
        guard let data = Data(base64Encoded: trimmed) else {
            throw ChannelsSettingsError.invalidKey
        }
        let bytes = [UInt8](data)
        guard bytes.count == 16 || bytes.count == 32 else {
            throw ChannelsSettingsError.invalidKey
        }
        return bytes
    }
}

@MainActor
@Observable
public final class ChannelsSettingsViewModel {
    /// MQTT channels (capped at 20, SPEC §10).
    public private(set) var mqttChannels: [ChannelEntry] = []
    /// Local-device channels (capped at 7, SPEC §10).
    public private(set) var localChannels: [ChannelEntry] = []
    /// The last error to surface in the UI, cleared on the next successful action.
    public private(set) var lastError: ChannelsSettingsError?

    @ObservationIgnored private let keys: any ChannelKeyManaging

    public init(keys: any ChannelKeyManaging) {
        self.keys = keys
    }

    /// Load (or refresh) the channel list from the port. Call this from `.task` /
    /// `.onAppear`. Failures surface in `lastError` rather than throwing to the UI.
    public func load() async {
        await reload()
    }

    // MARK: - Derived state

    /// Whether another channel of `kind` may be added (under the SPEC §10 cap).
    public func canAdd(_ kind: ChannelKind) -> Bool {
        channels(for: kind).count < kind.capacity
    }

    /// Capacity label for a section header. Finite kinds show "3 / 7"; the
    /// uncapped MQTT kind shows a plain count ("3 channels") with no cap.
    public func capacityLabel(for kind: ChannelKind) -> String {
        let count = channels(for: kind).count
        guard kind.hasFiniteCapacity else {
            return count == 1 ? "1 channel" : "\(count) channels"
        }
        return "\(count) / \(kind.capacity)"
    }

    private func channels(for kind: ChannelKind) -> [ChannelEntry] {
        switch kind {
        case .mqtt: mqttChannels
        case .local: localChannels
        }
    }

    // MARK: - Mutations

    /// Add a channel by name. The hash is derived from the name with the default
    /// PSK so a fresh channel decodes default traffic until a key is rotated in;
    /// the channel starts keyless (`hasKey == false`) until a PSK is set.
    public func addChannel(name: String, kind: ChannelKind) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = .emptyName
            return
        }
        guard canAdd(kind) else {
            lastError = .capacityReached(kind)
            return
        }
        let hash = ChannelKeyMath.channelHash(name: trimmed, psk: ChannelKeyMath.defaultPSK)
        guard !channelExists(hash: hash) else {
            lastError = .duplicateChannel
            return
        }
        await perform { try await keys.addChannel(name: trimmed, hash: hash, kind: kind) }
    }

    /// Set or rotate the PSK for `hash` from user-entered text. Accepts base64 or
    /// the `"AQ=="` default-key shortcut. The plaintext never returns to the UI.
    public func setKey(forChannelHash hash: UInt32, pskText: String) async {
        let psk: [UInt8]
        do {
            psk = try ChannelKeyMath.parsePSK(pskText)
        } catch let error as ChannelsSettingsError {
            lastError = error
            return
        } catch {
            lastError = .invalidKey
            return
        }
        await store(ChannelKey(psk: psk), forChannelHash: hash)
    }

    /// Apply the well-known default PSK to `hash` (the "use default PSK" toggle /
    /// shortcut). Equivalent to entering `"AQ=="`.
    public func useDefaultKey(forChannelHash hash: UInt32) async {
        await store(ChannelKey(psk: ChannelKeyMath.defaultPSK), forChannelHash: hash)
    }

    /// Remove the PSK for `hash`, leaving the channel registered but keyless.
    public func clearKey(forChannelHash hash: UInt32) async {
        await perform { try await keys.clearKey(forChannelHash: hash) }
    }

    /// Remove a channel entirely (and any key held for it).
    public func removeChannel(hash: UInt32) async {
        await perform { try await keys.removeChannel(hash: hash) }
    }

    // MARK: - Helpers

    private func store(_ key: ChannelKey, forChannelHash hash: UInt32) async {
        await perform { try await keys.setKey(key, forChannelHash: hash) }
    }

    /// Run a port mutation, then refresh. On failure, surface a redacted
    /// `storeFailed` — `String(describing:)` of our typed errors carries no secret.
    private func perform(_ mutation: () async throws -> Void) async {
        do {
            try await mutation()
            lastError = nil
            await reload()
        } catch {
            lastError = .storeFailed(String(describing: error))
        }
    }

    private func channelExists(hash: UInt32) -> Bool {
        mqttChannels.contains { $0.hash == hash } || localChannels.contains { $0.hash == hash }
    }

    private func reload() async {
        do {
            let all = try await keys.channels()
            mqttChannels = all.filter { $0.kind == .mqtt }
            localChannels = all.filter { $0.kind == .local }
        } catch {
            lastError = .storeFailed(String(describing: error))
        }
    }
}

/// In-memory `ChannelKeyManaging` for tests and the preview. Holds channel
/// metadata and PSK bytes in process memory only — no Keychain, no logging. The
/// production path is the lead's `KeychainKeyStore` adapter.
///
/// Implemented as an `actor` so its mutable state is isolated without locks and it
/// satisfies the now-`async` `ChannelKeyManaging` port directly.
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
