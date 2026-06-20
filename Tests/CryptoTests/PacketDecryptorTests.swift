@testable import Crypto
import Domain
import Testing

/// Tests for the AES-CTR `PacketDecryptor`.
///
/// Coverage targets (DoD): round-trip for AES-128 and AES-256, invalid key
/// length throws, and a known-answer vector computed by an independent AES-CTR
/// implementation (OpenSSL) to pin the nonce layout + keystream.
@Suite("AES-CTR PacketDecryptor")
struct PacketDecryptorTests {
    private let decryptor = AESCTRPacketDecryptor()

    // MARK: - Round-trip (encrypt with the CTR keystream, then decrypt)

    @Test
    func `AES-128 round-trips arbitrary plaintext back to the original`() throws {
        let key = ChannelKey(psk: Array(repeating: 0xAB, count: 16))
        let plaintext: [UInt8] = Array("the quick brown fox jumps".utf8)
        let packetID: UInt32 = 0xDEAD_BEEF
        let fromNode: UInt32 = 0x0102_0304

        // CTR is symmetric, so the encryptor is the same core transform.
        let ciphertext = try AESCTRPacketDecryptor.crypt(
            plaintext, packetID: packetID, fromNode: fromNode, key: key
        )
        #expect(ciphertext != plaintext) // it actually encrypted something

        let recovered = try decryptor.decrypt(
            ciphertext, packetID: packetID, fromNode: fromNode, key: key
        )
        #expect(recovered == plaintext)
    }

    @Test
    func `AES-256 round-trips arbitrary plaintext back to the original`() throws {
        let key = ChannelKey(psk: Array(0 ..< 32).map { UInt8($0) })
        let plaintext: [UInt8] = Array("a longer payload exercising multiple AES blocks here".utf8)
        let packetID: UInt32 = 0x0000_0001
        let fromNode: UInt32 = 0xFFFF_FFFF

        let ciphertext = try AESCTRPacketDecryptor.crypt(
            plaintext, packetID: packetID, fromNode: fromNode, key: key
        )
        let recovered = try decryptor.decrypt(
            ciphertext, packetID: packetID, fromNode: fromNode, key: key
        )
        #expect(recovered == plaintext)
    }

    @Test
    func `empty payload decrypts to empty`() throws {
        let key = ChannelKey(psk: Array(repeating: 0x00, count: 16))
        let recovered = try decryptor.decrypt([], packetID: 1, fromNode: 2, key: key)
        #expect(recovered.isEmpty)
    }

    @Test
    func `payload spanning several blocks round-trips`() throws {
        let key = ChannelKey(psk: Array(repeating: 0x5A, count: 32))
        // 100 bytes spans >6 AES blocks, so the CTR counter must increment past
        // the initial nonce block correctly.
        let plaintext = (0 ..< 100).map { UInt8($0 & 0xFF) }
        let ciphertext = try AESCTRPacketDecryptor.crypt(
            plaintext, packetID: 7, fromNode: 9, key: key
        )
        let recovered = try decryptor.decrypt(ciphertext, packetID: 7, fromNode: 9, key: key)
        #expect(recovered == plaintext)
    }

    // MARK: - Invalid key length

    @Test(arguments: [0, 1, 8, 15, 17, 24, 31, 33, 64])
    func `non-AES key sizes throw invalidKeyLength`(badLength: Int) {
        let key = ChannelKey(psk: Array(repeating: 0xFF, count: badLength))
        #expect(throws: DecryptionError.invalidKeyLength(badLength)) {
            try decryptor.decrypt([0x00], packetID: 1, fromNode: 2, key: key)
        }
    }

    @Test
    func `24-byte (AES-192) key is rejected per spec (only 16 or 32 allowed)`() {
        // SPEC §2.5 admits AES-128 and AES-256 only; AES-192 must be rejected.
        let key = ChannelKey(psk: Array(repeating: 0x11, count: 24))
        #expect(throws: DecryptionError.invalidKeyLength(24)) {
            try decryptor.decrypt([0x00], packetID: 1, fromNode: 2, key: key)
        }
    }

    // MARK: - Nonce layout

    @Test
    func `nonce matches the Meshtastic initNonce little-endian layout`() {
        // packetID 0x11223344, fromNode 0x55667788.
        let nonce = AESCTRPacketDecryptor.initNonce(packetID: 0x1122_3344, fromNode: 0x5566_7788)
        let expected: [UInt8] = [
            // packetID as 64-bit LE (high word zero):
            0x44, 0x33, 0x22, 0x11, 0x00, 0x00, 0x00, 0x00,
            // fromNode as 32-bit LE:
            0x88, 0x77, 0x66, 0x55,
            // block counter / extraNonce (zero):
            0x00, 0x00, 0x00, 0x00
        ]
        #expect(nonce == expected)
        #expect(nonce.count == 16)
    }

    // MARK: - Known-answer vectors (independent OpenSSL AES-CTR)

    @Test
    func `AES-128 known-answer vector matches OpenSSL keystream`() throws {
        // Computed with: openssl enc -aes-128-ctr -K <key> -iv <nonce-as-BE-block> -nosalt
        // key   = d4f1bb3a20290759f0bcffabcf4e6901 (Meshtastic default channel key)
        // packetID = 0x12345678, fromNode = 0x9abcdef0
        // nonce  = 78 56 34 12 00 00 00 00  f0 de bc 9a  00 00 00 00  (LE layout)
        let key = ChannelKey(psk: [
            0xD4, 0xF1, 0xBB, 0x3A, 0x20, 0x29, 0x07, 0x59,
            0xF0, 0xBC, 0xFF, 0xAB, 0xCF, 0x4E, 0x69, 0x01
        ])
        let plaintext: [UInt8] = Array("Hello, Meshtastic!".utf8)
        let expectedCiphertext: [UInt8] = [
            0xFD, 0x5C, 0xCD, 0x8B, 0x81, 0x13, 0xC4, 0xBC,
            0x74, 0x08, 0x69, 0x78, 0xD5, 0x0D, 0x9E, 0x1E,
            0x5A, 0x27
        ]

        let produced = try AESCTRPacketDecryptor.crypt(
            plaintext, packetID: 0x1234_5678, fromNode: 0x9ABC_DEF0, key: key
        )
        #expect(produced == expectedCiphertext)

        // And the public decrypt path inverts it.
        let recovered = try decryptor.decrypt(
            expectedCiphertext, packetID: 0x1234_5678, fromNode: 0x9ABC_DEF0, key: key
        )
        #expect(recovered == plaintext)
    }

    @Test
    func `AES-256 known-answer vector matches OpenSSL keystream`() throws {
        // openssl enc -aes-256-ctr; packetID = 1, fromNode = 2.
        let key = ChannelKey(psk: Array(0 ..< 32).map { UInt8($0) })
        let plaintext: [UInt8] = Array("meshtrack-256".utf8)
        let expectedCiphertext: [UInt8] = [
            0x23, 0xC9, 0x5D, 0x08, 0xAB, 0x44, 0x42, 0x15,
            0x11, 0x60, 0x6C, 0x69, 0xF0
        ]

        let produced = try AESCTRPacketDecryptor.crypt(
            plaintext, packetID: 1, fromNode: 2, key: key
        )
        #expect(produced == expectedCiphertext)
    }
}
