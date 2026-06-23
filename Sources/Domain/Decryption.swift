// Decryption + key-management seam (Phase 1, SPEC §2.5). Ports only — the AES
// implementation lives in the `Crypto` adapter and the durable key store in
// `Persistence`; Domain stays pure (no CryptoKit, no Foundation).

/// A channel pre-shared key. 16 bytes → AES-128, 32 bytes → AES-256. Held only
/// in memory here; the durable copy lives in the local `app_config` store
/// (`DatabaseKeyStore`).
public struct ChannelKey: Sendable, Equatable {
    public let psk: [UInt8]

    public init(psk: [UInt8]) {
        self.psk = psk
    }
}

/// Port: resolves the channel key for a packet. Production is the local
/// SQLite-backed `DatabaseKeyStore`; tests use an in-memory fake. Holds up to
/// 20 MQTT / 7 local channel keys (SPEC §10).
public protocol KeyStore: Sendable {
    /// The key for a Meshtastic channel hash (`MeshPacket.channel`), if held.
    func key(forChannelHash channelHash: UInt32) -> ChannelKey?
}

/// Port: decrypts an encrypted `MeshPacket` payload (SPEC §2.5). The Meshtastic
/// scheme is AES-CTR with a 128-bit nonce derived from `(packetID, fromNode)`.
public protocol PacketDecryptor: Sendable {
    func decrypt(
        _ ciphertext: [UInt8],
        packetID: UInt32,
        fromNode: UInt32,
        key: ChannelKey
    ) throws -> [UInt8]
}

/// Typed decryption failures — no force-unwraps, callers get a precise reason.
public enum DecryptionError: Error, Equatable, Sendable {
    /// The key length was not a valid AES key size (16 or 32 bytes).
    case invalidKeyLength(Int)
    /// The underlying cipher operation failed.
    case cipherFailed(String)
}
