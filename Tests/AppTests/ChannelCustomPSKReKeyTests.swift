@testable import App
import Domain
import Foundation
import Testing

/// Re-keying a name-derived channel under the correct custom-PSK hash (Phase 9,
/// Finding 15). A focused suite so the main settings suite stays under the body cap.
@Suite("ChannelCustomPSKReKey")
@MainActor
struct ChannelCustomPSKReKeyTests {
    private func makeVM() -> (ChannelsSettingsViewModel, InMemoryChannelKeyManager) {
        let keys = InMemoryChannelKeyManager()
        return (ChannelsSettingsViewModel(keys: keys), keys)
    }

    private let customKeyB64 = Data(Array(repeating: UInt8(0xAB), count: 16)).base64EncodedString()

    @Test
    func `setting a custom PSK re-files the channel under the PSK-derived hash`() async throws {
        let (vm, store) = makeVM()
        // Operator adds a channel by name only → registered under the default-PSK hash.
        await vm.addChannel(name: "OpsNet", kind: .mqtt)
        let defaultHash = ChannelKeyMath.channelHash(name: "OpsNet", psk: ChannelKeyMath.defaultPSK)
        #expect(vm.mqttChannels.map(\.hash) == [defaultHash])

        // ...then sets a custom PSK. The on-wire hash for that PSK is what matters.
        let customPSK = [UInt8](Data(base64Encoded: customKeyB64) ?? Data())
        let wireHash = ChannelKeyMath.channelHash(name: "OpsNet", psk: customPSK)
        await vm.setKey(forChannelHash: defaultHash, pskText: customKeyB64)
        #expect(vm.lastError == nil)

        // The channel now lives under the custom-PSK hash, keyed with the custom PSK,
        // and the stale default-PSK row is gone — live decode keyed by `wireHash` hits.
        let entry = try #require(vm.mqttChannels.first)
        #expect(vm.mqttChannels.count == 1)
        #expect(entry.name == "OpsNet")
        #expect(entry.hash == wireHash)
        #expect(entry.hasKey == true)
        #expect(await store.storedKey(forChannelHash: wireHash)?.psk == customPSK)
        #expect(await store.storedKey(forChannelHash: defaultHash) == nil)
    }

    @Test
    func `a packet whose hash is derived from the custom PSK resolves to that channel`() async {
        let (vm, store) = makeVM()
        await vm.addChannel(name: "OpsNet", kind: .mqtt)
        let defaultHash = ChannelKeyMath.channelHash(name: "OpsNet", psk: ChannelKeyMath.defaultPSK)
        let customPSK = [UInt8](Data(base64Encoded: customKeyB64) ?? Data())
        await vm.setKey(forChannelHash: defaultHash, pskText: customKeyB64)

        // The decoder's KeyStore is the channel registry. A packet arriving on the
        // hash the radios actually put on the wire (name⊕customPSK) must resolve to
        // the custom PSK via the same resolver the live path uses.
        let resolver = await ChannelKeyResolver(
            primary: KeyStoreAdapter(store),
            defaultKey: ChannelKey(psk: ChannelKeyMath.defaultPSK)
        )
        let wireHash = ChannelKeyMath.channelHash(name: "OpsNet", psk: customPSK)
        #expect(resolver.key(forChannelHash: wireHash)?.psk == customPSK)
    }

    @Test
    func `the default-PSK shortcut leaves the name-derived hash unchanged`() async {
        let (vm, store) = makeVM()
        await vm.addChannel(name: "PubNet", kind: .mqtt)
        let defaultHash = ChannelKeyMath.channelHash(name: "PubNet", psk: ChannelKeyMath.defaultPSK)

        // Applying the default PSK recomputes the same hash → no migration.
        await vm.setKey(forChannelHash: defaultHash, pskText: "AQ==")
        #expect(vm.mqttChannels.map(\.hash) == [defaultHash])
        #expect(await store.storedKey(forChannelHash: defaultHash)?.psk == ChannelKeyMath.defaultPSK)
    }

    @Test
    func `an explicit observed hash is not re-keyed when a custom PSK is set`() async {
        let (vm, store) = makeVM()
        // Operator pins the channel to an observed wire hash (explicit hashText).
        await vm.addChannel(name: "Pinned", hashText: "0x2A", kind: .mqtt)
        #expect(vm.mqttChannels.map(\.hash) == [0x2A])

        // Setting a custom PSK must NOT move it: 0x2A is ground truth from the wire.
        await vm.setKey(forChannelHash: 0x2A, pskText: customKeyB64)
        #expect(vm.lastError == nil)
        #expect(vm.mqttChannels.map(\.hash) == [0x2A])
        let customPSK = [UInt8](Data(base64Encoded: customKeyB64) ?? Data())
        #expect(await store.storedKey(forChannelHash: 0x2A)?.psk == customPSK)
    }
}

/// Bridges the test's `InMemoryChannelKeyManager` (an actor) to the synchronous
/// `KeyStore` the resolver consults, by snapshotting its keys at construction. The
/// live app uses the lead's Keychain-backed `KeyStore`; this fake mirrors the seam.
private struct KeyStoreAdapter: KeyStore {
    private let keysByHash: [UInt32: ChannelKey]
    init(_ store: InMemoryChannelKeyManager) async {
        var snapshot: [UInt32: ChannelKey] = [:]
        for entry in await store.channels() {
            if let key = await store.storedKey(forChannelHash: entry.hash) {
                snapshot[entry.hash] = key
            }
        }
        keysByHash = snapshot
    }

    func key(forChannelHash channelHash: UInt32) -> ChannelKey? {
        keysByHash[channelHash]
    }
}
