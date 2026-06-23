// Tests for the local, on-device secret stores that replaced the Keychain adapters:
// channel PSKs (`DatabaseKeyStore`) and the broker password (`DatabaseCredentialStore`),
// both persisted as JSON in the app's own `app_config` table. These verify the
// round-trip, persistence across instances (the share-one-DB contract the live decoder
// and the Settings screen rely on), rotation, and clearing.

import Domain
@testable import Persistence
import Testing

@Suite("Local secret stores (app_config-backed)")
struct DatabaseSecretStoresTests {
    private func makeStore() throws -> MeshStore {
        try MeshStore(DatabaseConnection.inMemory())
    }

    @Test
    func `channel keys round-trip and persist across instances over the same DB`() throws {
        let store = try makeStore()
        let keys = DatabaseKeyStore(store)
        #expect(keys.key(forChannelHash: 0x42) == nil)

        try keys.store(ChannelKey(psk: [1, 2, 3, 4]), forChannelHash: 0x42)
        #expect(keys.key(forChannelHash: 0x42)?.psk == [1, 2, 3, 4])

        // A second store over the same DB reads the persisted key — the contract the
        // Settings screen + live decoder rely on when sharing one instance.
        #expect(DatabaseKeyStore(store).key(forChannelHash: 0x42)?.psk == [1, 2, 3, 4])

        try keys.removeKey(forChannelHash: 0x42)
        #expect(keys.key(forChannelHash: 0x42) == nil)
        #expect(DatabaseKeyStore(store).key(forChannelHash: 0x42) == nil)
    }

    @Test
    func `multiple channel keys coexist and rotate independently`() throws {
        let store = try makeStore()
        let keys = DatabaseKeyStore(store)
        try keys.store(ChannelKey(psk: [0xAA]), forChannelHash: 1)
        try keys.store(ChannelKey(psk: [0xBB]), forChannelHash: 2)
        try keys.store(ChannelKey(psk: [0xCC]), forChannelHash: 1) // rotate #1

        #expect(keys.key(forChannelHash: 1)?.psk == [0xCC])
        #expect(keys.key(forChannelHash: 2)?.psk == [0xBB])
    }

    @Test
    func `broker password round-trips, rotates, and clears`() throws {
        let store = try makeStore()
        let creds = DatabaseCredentialStore(store)
        #expect(creds.password(host: "h", username: "u") == nil)

        try creds.setPassword("secret", host: "h", username: "u")
        #expect(creds.password(host: "h", username: "u") == "secret")
        #expect(DatabaseCredentialStore(store).password(host: "h", username: "u") == "secret")

        try creds.setPassword("rotated", host: "h", username: "u")
        #expect(creds.password(host: "h", username: "u") == "rotated")

        try creds.setPassword(nil, host: "h", username: "u") // nil clears
        #expect(creds.password(host: "h", username: "u") == nil)
    }

    @Test
    func `anonymous and named accounts on the same host stay distinct`() throws {
        let store = try makeStore()
        let creds = DatabaseCredentialStore(store)
        try creds.setPassword("anon", host: "h", username: nil)
        try creds.setPassword("named", host: "h", username: "u")
        #expect(creds.password(host: "h", username: nil) == "anon")
        #expect(creds.password(host: "h", username: "u") == "named")
    }

    @Test
    func `account joins host and username with a pipe, distinct per identity`() {
        #expect(DatabaseCredentialStore.account(host: "mqtt.bayme.sh", username: "clive")
            == "mqtt.bayme.sh|clive")
        #expect(DatabaseCredentialStore.account(host: "h", username: nil) == "h|")
        let accounts = Set([
            DatabaseCredentialStore.account(host: "h1", username: "u"),
            DatabaseCredentialStore.account(host: "h2", username: "u"),
            DatabaseCredentialStore.account(host: "h1", username: "v")
        ])
        #expect(accounts.count == 3)
    }
}
