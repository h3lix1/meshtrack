// MeshtasticChannelHash — the ONE source of truth for the Meshtastic channel-hash
// fold and the well-known default channel PSK, shared across the App library.
//
// Both the Channels & Keys settings screen (`ChannelKeyMath`) and the map's
// preset resolver (`ChannelPreset`) need the firmware's `Channels::generateHash`
// (`xorHash(name) ^ xorHash(psk)`) and the 16-byte default key. Keeping two copies
// risked drift: a change on one screen could leave traffic decoding on the other
// and silently failing on this one. This enum is that shared, pure, headless-
// testable helper; both call sites delegate to it so the hash + PSK can only ever
// be defined once.
//
// `public` so the executable's live composition root (`LiveCoordinator`) resolves
// channel keys by the exact same hash the settings UI registers them under.

import Foundation

/// Pure helpers for Meshtastic channel identity: the on-wire channel hash and the
/// well-known default PSK. No state; safe to use from any actor.
public enum MeshtasticChannelHash {
    /// The well-known default 16-byte channel PSK — Meshtastic's expansion of the
    /// 1-byte key `0x01` (written `"AQ=="` in base64). Every public preset
    /// (LongFast, MediumFast, …) uses this PSK, so those channels' hashes depend
    /// only on the name (SPEC §1, §10).
    public static let defaultPSK: [UInt8] = [
        0xD4, 0xF1, 0xBB, 0x3A, 0x20, 0x29, 0x07, 0x59,
        0xF0, 0xBC, 0xFF, 0xAB, 0xCF, 0x4E, 0x69, 0x01
    ]

    /// The Meshtastic `MeshPacket.channel` hash: a single XOR fold of every byte of
    /// the channel name XOR'd with every byte of the PSK, widened to `UInt32`
    /// (matches the firmware's `generateHash` → `xorHash(name) ^ xorHash(psk)`).
    /// The default channel hashes the same way the radios do, so traffic decodes.
    public static func channelHash(name: String, psk: [UInt8]) -> UInt32 {
        UInt32(xorFold(Array(name.utf8)) ^ xorFold(psk))
    }

    /// XOR-fold a byte sequence to a single byte (the firmware's `xorHash`).
    private static func xorFold(_ bytes: [UInt8]) -> UInt8 {
        bytes.reduce(UInt8(0)) { $0 ^ $1 }
    }
}
