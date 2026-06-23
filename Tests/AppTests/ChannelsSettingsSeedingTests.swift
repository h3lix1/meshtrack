@testable import App
import Domain
import Testing

/// First-run seeding of the default MediumFast + "AQ==" channel (Phase 9,
/// T-Channels). A separate suite/file so the load-path seeding stays focused and
/// the main settings suite remains under the file/body-size caps.
@Suite("ChannelDefaultSeeding")
@MainActor
struct ChannelDefaultSeedingTests {
    @Test
    func `first load over an empty registry seeds MediumFast keyed with the default PSK`() async throws {
        let keys = InMemoryChannelKeyManager()
        let vm = ChannelsSettingsViewModel(keys: keys)
        await vm.load()

        // Exactly one MQTT channel — the public MediumFast — and no local ones.
        #expect(vm.localChannels.isEmpty)
        let entry = try #require(vm.mqttChannels.first)
        #expect(vm.mqttChannels.count == 1)
        #expect(entry.name == "MediumFast")
        #expect(entry.hash == 0x1F) // well-known MediumFast hash
        #expect(entry.hasKey == true) // keyed out of the box
        #expect(vm.lastError == nil)

        // The store holds the actual default PSK (never surfaced to the UI).
        #expect(await keys.storedKey(forChannelHash: entry.hash)?.psk == ChannelKeyMath.defaultPSK)
    }

    @Test
    func `seeding does not run when the operator already has channels`() async {
        let keys = InMemoryChannelKeyManager()
        // A pre-existing, unrelated channel means this is not a first run.
        let existing = ChannelKeyMath.channelHash(name: "BayMesh", psk: ChannelKeyMath.defaultPSK)
        await keys.addChannel(name: "BayMesh", hash: existing, kind: .mqtt)

        let vm = ChannelsSettingsViewModel(keys: keys)
        await vm.load()

        // Only the operator's channel — no MediumFast was injected on top.
        #expect(vm.mqttChannels.map(\.name) == ["BayMesh"])
        #expect(vm.localChannels.isEmpty)
    }

    @Test
    func `seeding is idempotent — it does not re-seed on a second load`() async {
        let keys = InMemoryChannelKeyManager()
        let vm = ChannelsSettingsViewModel(keys: keys)
        await vm.load()
        #expect(vm.mqttChannels.count == 1)

        await vm.load()
        #expect(vm.mqttChannels.count == 1) // still just the one seed, not two
    }

    @Test
    func `removing the seeded default does not bring it back on the next load`() async throws {
        let keys = InMemoryChannelKeyManager()
        let vm = ChannelsSettingsViewModel(keys: keys)
        await vm.load()
        let hash = try #require(vm.mqttChannels.first).hash

        // The operator deletes the default channel...
        await vm.removeChannel(hash: hash)
        #expect(vm.mqttChannels.isEmpty)

        // ...and a refresh must not silently recreate it.
        await vm.load()
        #expect(vm.mqttChannels.isEmpty)
        #expect(vm.localChannels.isEmpty)
    }
}
