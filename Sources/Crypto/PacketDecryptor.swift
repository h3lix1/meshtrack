// Crypto — the decryption adapter (SPEC §2.5). Implements the Domain port
// `PacketDecryptor` using Meshtastic's AES-CTR scheme.
//
// CryptoKit deliberately omits AES-CTR (it favours authenticated modes), so we
// drop down to CommonCrypto's lower-level `CCCryptor` API, which supports CTR
// via `kCCModeCTR`. CTR is a stream cipher: encryption and decryption are the
// same operation (XOR the keystream), so this one routine handles both.

import CommonCrypto
import Domain

/// AES-CTR implementation of `Domain.PacketDecryptor`, matching the Meshtastic
/// firmware `CryptoEngine`.
///
/// The type is stateless and therefore trivially `Sendable`: every call derives
/// its own nonce and spins up a fresh `CCCryptorRef`, so concurrent decryptions
/// never share mutable state.
public struct AESCTRPacketDecryptor: PacketDecryptor {
    public init() {}

    public func decrypt(
        _ ciphertext: [UInt8],
        packetID: UInt32,
        fromNode: UInt32,
        key: ChannelKey
    ) throws -> [UInt8] {
        try Self.crypt(ciphertext, packetID: packetID, fromNode: fromNode, key: key)
    }

    // MARK: - Core CTR transform

    /// XORs `input` against the AES-CTR keystream. Because CTR is symmetric this
    /// is used for both decrypt (ciphertext → plaintext) and, in tests, encrypt
    /// (plaintext → ciphertext).
    ///
    /// Throws `DecryptionError.invalidKeyLength` for any key that is not a legal
    /// AES size, and `DecryptionError.cipherFailed` if CommonCrypto reports an
    /// error.
    static func crypt(
        _ input: [UInt8],
        packetID: UInt32,
        fromNode: UInt32,
        key: ChannelKey
    ) throws -> [UInt8] {
        let keyLength = key.psk.count
        guard keyLength == kCCKeySizeAES128 || keyLength == kCCKeySizeAES256 else {
            throw DecryptionError.invalidKeyLength(keyLength)
        }

        // CTR turns AES into a stream cipher, so the output is exactly the input
        // length (no padding, no block rounding). An empty payload is valid and
        // yields an empty result.
        var output = [UInt8](repeating: 0, count: input.count)
        if input.isEmpty {
            return output
        }

        let nonce = initNonce(packetID: packetID, fromNode: fromNode)
        let cryptor = try makeCTRCryptor(key: key.psk, keyLength: keyLength, nonce: nonce)
        defer { CCCryptorRelease(cryptor) }

        var moved = 0
        let updateStatus = input.withUnsafeBytes { inPtr in
            output.withUnsafeMutableBytes { outPtr in
                CCCryptorUpdate(
                    cryptor,
                    inPtr.baseAddress,
                    input.count,
                    outPtr.baseAddress,
                    outPtr.count,
                    &moved
                )
            }
        }
        guard updateStatus == kCCSuccess else {
            throw DecryptionError.cipherFailed("CCCryptorUpdate failed (status \(updateStatus))")
        }

        // CTR produces no buffered/final bytes, but call CCCryptorFinal for
        // completeness and to surface any late error.
        var finalMoved = 0
        let finalStatus = output.withUnsafeMutableBytes { outPtr in
            CCCryptorFinal(
                cryptor,
                outPtr.baseAddress?.advanced(by: moved),
                outPtr.count - moved,
                &finalMoved
            )
        }
        guard finalStatus == kCCSuccess else {
            throw DecryptionError.cipherFailed("CCCryptorFinal failed (status \(finalStatus))")
        }

        return output
    }

    /// Creates an AES-CTR `CCCryptorRef` for `key` and the initial counter
    /// `nonce`. The caller owns the returned cryptor and must `CCCryptorRelease`
    /// it. Throws `DecryptionError.cipherFailed` if CommonCrypto rejects the
    /// parameters.
    private static func makeCTRCryptor(
        key: [UInt8],
        keyLength: Int,
        nonce: [UInt8]
    ) throws -> CCCryptorRef {
        var cryptor: CCCryptorRef?
        let status = key.withUnsafeBytes { keyPtr in
            nonce.withUnsafeBytes { ivPtr in
                CCCryptorCreateWithMode(
                    CCOperation(kCCEncrypt), // CTR: encrypt == decrypt
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivPtr.baseAddress,
                    keyPtr.baseAddress,
                    keyLength,
                    nil, // tweak: unused for CTR
                    0,
                    0, // numRounds: 0 = default for the key size
                    CCModeOptions(kCCModeOptionCTR_BE), // big-endian counter increment
                    &cryptor
                )
            }
        }
        guard status == kCCSuccess, let cryptor else {
            throw DecryptionError.cipherFailed("CCCryptorCreateWithMode failed (status \(status))")
        }
        return cryptor
    }

    // MARK: - Nonce derivation

    /// Builds the 16-byte initial CTR counter block exactly as the Meshtastic
    /// firmware `CryptoEngine::initNonce` does.
    ///
    /// Firmware reference (`src/mesh/CryptoEngine.cpp`):
    /// ```c
    /// memset(nonce, 0, sizeof(nonce));
    /// memcpy(nonce,                    &packetId, sizeof(uint64_t)); // bytes 0..7
    /// memcpy(nonce + sizeof(uint64_t), &fromNode, sizeof(uint32_t)); // bytes 8..11
    /// // bytes 12..15 stay zero (block counter / optional extraNonce)
    /// ```
    /// The header documents the layout as little-endian, and all supported
    /// Meshtastic targets (ESP32, nRF52, RP2040) are little-endian, so we write
    /// the integers little-endian regardless of host architecture.
    ///
    /// Layout (16 bytes total):
    ///   - bytes[0..8)   `packetID` as a 64-bit LE integer (high 32 bits are 0,
    ///                   since `packetID` is a 32-bit value here)
    ///   - bytes[8..12)  `fromNode` as a 32-bit LE integer
    ///   - bytes[12..16) zero (block counter, starts at 0; no extraNonce)
    static func initNonce(packetID: UInt32, fromNode: UInt32) -> [UInt8] {
        var nonce = [UInt8](repeating: 0, count: 16)
        // packetID widened to 64 bits; the upper word is therefore all zero,
        // matching the firmware which passes a uint64_t packet number.
        let packetID64 = UInt64(packetID)
        for byteIndex in 0 ..< 8 {
            nonce[byteIndex] = UInt8(truncatingIfNeeded: packetID64 >> (8 * byteIndex))
        }
        for byteIndex in 0 ..< 4 {
            nonce[8 + byteIndex] = UInt8(truncatingIfNeeded: fromNode >> (8 * byteIndex))
        }
        // bytes[12..16) remain zero.
        return nonce
    }
}
