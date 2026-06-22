// ChannelPreset — resolves a Meshtastic channel hash (the byte carried in
// `MeshPacket.channel`, surfaced on DecodedPacket.channel) back to a human preset
// name, so the map can filter nodes/traces by channel (Task 4).
//
// Meshtastic computes a channel's hash as a single XOR fold of the channel *name*
// bytes XOR'd with the channel *PSK* bytes (firmware: `Channels::generateHash` →
// `xorHash(name) ^ xorHash(psk)`). The well-known presets ("LongFast",
// "MediumFast", …) all use the DEFAULT PSK — the 1-byte key `0x01`, which the
// firmware expands to the 16-byte AES key `d4f1bb3a20290759f0bcffabcf4e6901`. We
// fold that expanded key here so the hashes match what devices actually transmit.
//
// This is intentionally self-contained — it does NOT import the Settings module
// (per the task). Pure + unit-tested headless.

import Foundation

/// A well-known Meshtastic modem preset usable as a channel name.
public enum ChannelPreset: String, CaseIterable, Sendable, Identifiable {
    case longFast = "LongFast"
    case longSlow = "LongSlow"
    case longModerate = "LongMod"
    case mediumFast = "MediumFast"
    case mediumSlow = "MediumSlow"
    case shortFast = "ShortFast"
    case shortSlow = "ShortSlow"
    case shortTurbo = "ShortTurbo"

    public var id: String {
        rawValue
    }

    /// A short human label for the filter UI.
    public var displayName: String {
        switch self {
        case .longFast: "Long / Fast"
        case .longSlow: "Long / Slow"
        case .longModerate: "Long / Moderate"
        case .mediumFast: "Medium / Fast"
        case .mediumSlow: "Medium / Slow"
        case .shortFast: "Short / Fast"
        case .shortSlow: "Short / Slow"
        case .shortTurbo: "Short / Turbo"
        }
    }

    /// The default 16-byte channel PSK (Meshtastic's expansion of the 1-byte key
    /// `0x01`). Every public preset uses this PSK, so its hash is name-dependent only.
    /// Single source of truth: `MeshtasticChannelHash.defaultPSK`.
    static var defaultPSK: [UInt8] {
        MeshtasticChannelHash.defaultPSK
    }

    /// The channel hash a device transmits for this preset (the byte in
    /// `MeshPacket.channel`): XOR-fold of the name bytes XOR the PSK fold.
    public var channelHash: UInt32 {
        Self.hash(name: rawValue, psk: Self.defaultPSK)
    }

    /// Resolve a transmitted channel hash back to a preset, or nil if unknown.
    public static func preset(forHash hash: UInt32) -> ChannelPreset? {
        allCases.first { $0.channelHash == hash }
    }

    /// Meshtastic's channel-hash fold: `xorBytes(name) ^ xorBytes(psk)`.
    /// Exposed `static` so tests can pin the algorithm independently of the presets.
    /// Delegates to the shared `MeshtasticChannelHash` so this resolver and the
    /// settings screen's `ChannelKeyMath` can never drift.
    static func hash(name: String, psk: [UInt8]) -> UInt32 {
        MeshtasticChannelHash.channelHash(name: name, psk: psk)
    }
}
