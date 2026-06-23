// ChannelKeyMath — pure channel-key math for the Channels & Keys screen: deriving
// the Meshtastic channel hash and parsing PSK / hash text. Split out of
// `ChannelsSettingsViewModel` so the view model file stays within the lint limit
// and the math can be unit-tested without the `@MainActor` VM.

import Foundation

/// Channel-key math: deriving the Meshtastic channel hash and parsing PSK text.
/// Pure and `nonisolated` so it can be unit-tested without the `@MainActor` VM.
public enum ChannelKeyMath {
    /// The well-known Meshtastic default channel key — PSK index `1`, written
    /// `"AQ=="` in base64 (a single `0x01` byte expands to these 16 bytes). Shared
    /// by the public LongFast/MediumFast channels (SPEC §1, §10). Single source of
    /// truth: `MeshtasticChannelHash.defaultPSK`.
    public static var defaultPSK: [UInt8] {
        MeshtasticChannelHash.defaultPSK
    }

    /// The Meshtastic `MeshPacket.channel` hash: XOR of every byte of the channel
    /// name with every byte of the PSK, as a single byte widened to `UInt32`
    /// (matches the firmware's `generateHash`). The default channel ("" name with
    /// the index-1 key) hashes the same way the radios do, so traffic decodes.
    /// Delegates to the shared `MeshtasticChannelHash` so the settings screen and
    /// the map's preset resolver can never drift.
    public static func channelHash(name: String, psk: [UInt8]) -> UInt32 {
        MeshtasticChannelHash.channelHash(name: name, psk: psk)
    }

    /// Parse user-entered channel-hash text into the on-wire hash byte. Accepts
    /// hex (`"0x1F"`, `"1f"`, `"#1f"`) or decimal (`"31"`). The Meshtastic channel
    /// hash is a single byte, so the value must be in `0...255`; anything else (or
    /// unparseable text) throws `invalidChannelHash`. Empty text is *not* an error
    /// here — callers treat it as "derive from the name" instead.
    public static func parseChannelHash(_ text: String) throws -> UInt32 {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isHex: Bool
        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            trimmed = String(trimmed.dropFirst(2))
            isHex = true
        } else if trimmed.hasPrefix("#") {
            trimmed = String(trimmed.dropFirst())
            isHex = true
        } else {
            isHex = false
        }
        guard let value = isHex ? UInt32(trimmed, radix: 16) : UInt32(trimmed, radix: 10),
              value <= 0xFF
        else {
            throw ChannelsSettingsError.invalidChannelHash
        }
        return value
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
