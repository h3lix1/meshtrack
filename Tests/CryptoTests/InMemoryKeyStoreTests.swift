@testable import Crypto
import Domain
import Testing

/// Tests for the in-memory `KeyStore` fake. The durable adapter (`DatabaseKeyStore`)
/// is covered by its own Persistence tests; this exercises the in-process fake.
@Suite("InMemoryKeyStore")
struct InMemoryKeyStoreTests {
    @Test
    func `returns nil for an unknown channel hash`() {
        let store = InMemoryKeyStore()
        #expect(store.key(forChannelHash: 0x1234) == nil)
    }

    @Test
    func `stores then gets a key by channel hash`() {
        let store = InMemoryKeyStore()
        let key = ChannelKey(psk: Array(repeating: 0xAB, count: 16))
        store.store(key, forChannelHash: 42)
        #expect(store.key(forChannelHash: 42) == key)
        // A different channel is still empty.
        #expect(store.key(forChannelHash: 43) == nil)
    }

    @Test
    func `can be seeded at construction`() {
        let key = ChannelKey(psk: Array(repeating: 0x01, count: 32))
        let store = InMemoryKeyStore(keys: [7: key])
        #expect(store.key(forChannelHash: 7) == key)
    }

    @Test
    func `storing again rotates the key in place`() {
        let store = InMemoryKeyStore()
        let original = ChannelKey(psk: Array(repeating: 0x00, count: 16))
        let rotated = ChannelKey(psk: Array(repeating: 0xFF, count: 16))
        store.store(original, forChannelHash: 1)
        store.store(rotated, forChannelHash: 1)
        #expect(store.key(forChannelHash: 1) == rotated)
    }

    @Test
    func `removeKey deletes the stored key`() {
        let store = InMemoryKeyStore()
        let key = ChannelKey(psk: Array(repeating: 0x7F, count: 16))
        store.store(key, forChannelHash: 9)
        store.removeKey(forChannelHash: 9)
        #expect(store.key(forChannelHash: 9) == nil)
    }

    @Test
    func `resolves a key that then decrypts a packet end-to-end`() throws {
        // Lightweight integration: KeyStore + PacketDecryptor cooperate the way
        // the ingestion pipeline will use them.
        let store = InMemoryKeyStore()
        let key = ChannelKey(psk: Array(repeating: 0x5A, count: 32))
        let channelHash: UInt32 = 0x08
        store.store(key, forChannelHash: channelHash)

        let plaintext: [UInt8] = Array("end to end".utf8)
        let ciphertext = try AESCTRPacketDecryptor.crypt(
            plaintext, packetID: 100, fromNode: 200, key: key
        )

        let resolved = try #require(store.key(forChannelHash: channelHash))
        let recovered = try AESCTRPacketDecryptor().decrypt(
            ciphertext, packetID: 100, fromNode: 200, key: resolved
        )
        #expect(recovered == plaintext)
    }
}
