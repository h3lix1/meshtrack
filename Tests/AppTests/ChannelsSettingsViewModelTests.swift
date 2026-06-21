@testable import App
import Domain
import Foundation
import Testing

@Suite("ChannelsSettingsViewModel")
@MainActor
struct ChannelsSettingsViewModelTests {
    // MARK: - Helpers

    private func makeVM() -> (ChannelsSettingsViewModel, InMemoryChannelKeyManager) {
        let keys = InMemoryChannelKeyManager()
        return (ChannelsSettingsViewModel(keys: keys), keys)
    }

    /// A valid 16-byte AES-128 key as base64, distinct from the default key.
    private let customKeyB64 = Data(Array(repeating: UInt8(0xAB), count: 16)).base64EncodedString()

    // MARK: - Channel-hash math

    @Test
    func `channel hash matches the Meshtastic name⊕psk xor`() {
        // XOR of "" name (no bytes) with the index-1 default key → XOR of its bytes.
        let expected = ChannelKeyMath.defaultPSK.reduce(UInt8(0)) { $0 ^ $1 }
        #expect(ChannelKeyMath.channelHash(name: "", psk: ChannelKeyMath.defaultPSK) == UInt32(expected))

        // A named channel folds the name bytes in too.
        let named = ChannelKeyMath.channelHash(name: "LongFast", psk: ChannelKeyMath.defaultPSK)
        var manual: UInt8 = 0
        for b in "LongFast".utf8 {
            manual ^= b
        }
        for b in ChannelKeyMath.defaultPSK {
            manual ^= b
        }
        #expect(named == UInt32(manual))
    }

    // MARK: - PSK parsing

    @Test
    func `parsePSK accepts the AQ default-key shortcut`() throws {
        #expect(try ChannelKeyMath.parsePSK("AQ==") == ChannelKeyMath.defaultPSK)
    }

    @Test
    func `parsePSK accepts base64 16 and 32 byte keys`() throws {
        #expect(try ChannelKeyMath.parsePSK(customKeyB64).count == 16)
        let key32 = Data(Array(repeating: UInt8(0x11), count: 32)).base64EncodedString()
        #expect(try ChannelKeyMath.parsePSK(key32).count == 32)
    }

    @Test
    func `parsePSK rejects empty, non-base64, and wrong-length keys`() {
        #expect(throws: ChannelsSettingsError.invalidKey) { try ChannelKeyMath.parsePSK("   ") }
        #expect(throws: ChannelsSettingsError.invalidKey) { try ChannelKeyMath.parsePSK("not base64!!") }
        // 8 bytes is not a valid AES key size.
        let short = Data(Array(repeating: UInt8(0), count: 8)).base64EncodedString()
        #expect(throws: ChannelsSettingsError.invalidKey) { try ChannelKeyMath.parsePSK(short) }
    }

    // MARK: - Add + caps

    @Test
    func `adding channels splits them into mqtt and local`() {
        let (vm, _) = makeVM()
        vm.addChannel(name: "Broker1", kind: .mqtt)
        vm.addChannel(name: "Device1", kind: .local)
        #expect(vm.mqttChannels.map(\.name) == ["Broker1"])
        #expect(vm.localChannels.map(\.name) == ["Device1"])
        #expect(vm.lastError == nil)
    }

    /// 21 channel names whose 1-byte Meshtastic hashes are all distinct, so the
    /// add path exercises the (un)capacity logic and not the legitimate duplicate
    /// rejection of two channels that collide to the same on-wire hash byte.
    private func distinctHashNames(_ count: Int) -> [String] {
        var names: [String] = []
        var hashes = Set<UInt32>()
        var index = 0
        while names.count < count {
            let name = "ch\(index)"
            let hash = ChannelKeyMath.channelHash(name: name, psk: ChannelKeyMath.defaultPSK)
            if hashes.insert(hash).inserted {
                names.append(name)
            }
            index += 1
        }
        return names
    }

    @Test
    func `mqtt has no cap — the 21st channel is allowed`() {
        let (vm, _) = makeVM()
        let names = distinctHashNames(21)
        for name in names.prefix(20) {
            vm.addChannel(name: name, kind: .mqtt)
        }
        #expect(vm.mqttChannels.count == 20)
        #expect(vm.canAdd(.mqtt)) // still room — MQTT is uncapped

        vm.addChannel(name: names[20], kind: .mqtt)
        #expect(vm.mqttChannels.count == 21)
        #expect(vm.lastError == nil)
        #expect(vm.canAdd(.mqtt))
    }

    @Test
    func `local cap is 7 — the 8th is rejected`() {
        let (vm, _) = makeVM()
        for i in 0 ..< 7 {
            vm.addChannel(name: "local-\(i)", kind: .local)
        }
        #expect(vm.localChannels.count == 7)
        #expect(vm.canAdd(.local) == false)

        vm.addChannel(name: "local-overflow", kind: .local)
        #expect(vm.localChannels.count == 7)
        #expect(vm.lastError == .capacityReached(.local))
    }

    @Test
    func `empty and duplicate names are rejected`() {
        let (vm, _) = makeVM()
        vm.addChannel(name: "   ", kind: .mqtt)
        #expect(vm.mqttChannels.isEmpty)
        #expect(vm.lastError == .emptyName)

        vm.addChannel(name: "dup", kind: .mqtt)
        vm.addChannel(name: "dup", kind: .mqtt)
        #expect(vm.mqttChannels.count == 1)
        #expect(vm.lastError == .duplicateChannel)
    }

    // MARK: - Set / rotate / clear / delete

    @Test
    func `setting a key flips hasKey and never re-exposes the plaintext`() throws {
        let (vm, store) = makeVM()
        vm.addChannel(name: "secure", kind: .mqtt)
        let hash = try #require(vm.mqttChannels.first).hash
        #expect(vm.mqttChannels.first?.hasKey == false)

        vm.setKey(forChannelHash: hash, pskText: customKeyB64)
        #expect(vm.lastError == nil)
        #expect(vm.mqttChannels.first?.hasKey == true)

        // The view model exposes only a boolean — no API returns the bytes.
        // The store holds the true PSK; the UI's ChannelEntry never does.
        let stored = try #require(store.storedKey(forChannelHash: hash))
        #expect(stored.psk == [UInt8](Data(base64Encoded: customKeyB64) ?? Data()))
        let entry = try #require(vm.mqttChannels.first)
        // ChannelEntry carries no psk field at all; only hasKey.
        #expect(entry.hasKey == true)
    }

    @Test
    func `rotating a key replaces the stored secret`() throws {
        let (vm, store) = makeVM()
        vm.addChannel(name: "rot", kind: .local)
        let hash = try #require(vm.localChannels.first).hash

        vm.setKey(forChannelHash: hash, pskText: customKeyB64)
        let first = try #require(store.storedKey(forChannelHash: hash))

        let other = Data(Array(repeating: UInt8(0x77), count: 16)).base64EncodedString()
        vm.setKey(forChannelHash: hash, pskText: other)
        let second = try #require(store.storedKey(forChannelHash: hash))

        #expect(first.psk != second.psk)
        #expect(second.psk == [UInt8](Data(base64Encoded: other) ?? Data()))
        #expect(vm.localChannels.first?.hasKey == true)
    }

    @Test
    func `the default-PSK shortcut stores the well-known key`() throws {
        let (vm, store) = makeVM()
        vm.addChannel(name: "pub", kind: .mqtt)
        let hash = try #require(vm.mqttChannels.first).hash

        vm.useDefaultKey(forChannelHash: hash)
        #expect(vm.mqttChannels.first?.hasKey == true)
        #expect(store.storedKey(forChannelHash: hash)?.psk == ChannelKeyMath.defaultPSK)
    }

    @Test
    func `the AQ text shortcut also stores the default key`() throws {
        let (vm, store) = makeVM()
        vm.addChannel(name: "pub2", kind: .mqtt)
        let hash = try #require(vm.mqttChannels.first).hash

        vm.setKey(forChannelHash: hash, pskText: "AQ==")
        #expect(store.storedKey(forChannelHash: hash)?.psk == ChannelKeyMath.defaultPSK)
    }

    @Test
    func `clearing a key keeps the channel but drops the secret`() throws {
        let (vm, store) = makeVM()
        vm.addChannel(name: "clr", kind: .mqtt)
        let hash = try #require(vm.mqttChannels.first).hash
        vm.useDefaultKey(forChannelHash: hash)
        #expect(vm.mqttChannels.first?.hasKey == true)

        vm.clearKey(forChannelHash: hash)
        #expect(vm.mqttChannels.count == 1)
        #expect(vm.mqttChannels.first?.hasKey == false)
        #expect(store.storedKey(forChannelHash: hash) == nil)
    }

    @Test
    func `deleting a channel removes it and its key`() throws {
        let (vm, store) = makeVM()
        vm.addChannel(name: "gone", kind: .local)
        let hash = try #require(vm.localChannels.first).hash
        vm.useDefaultKey(forChannelHash: hash)

        vm.removeChannel(hash: hash)
        #expect(vm.localChannels.isEmpty)
        #expect(store.storedKey(forChannelHash: hash) == nil)
    }

    @Test
    func `an invalid key text surfaces an error and leaves the channel keyless`() throws {
        let (vm, _) = makeVM()
        vm.addChannel(name: "bad", kind: .mqtt)
        let hash = try #require(vm.mqttChannels.first).hash

        vm.setKey(forChannelHash: hash, pskText: "totally not base64 $$$")
        #expect(vm.lastError == .invalidKey)
        #expect(vm.mqttChannels.first?.hasKey == false)
    }

    @Test
    func `capacity label shows local cap and an uncapped mqtt count`() {
        let (vm, _) = makeVM()
        // Local enforces and shows its 7-channel cap.
        #expect(vm.capacityLabel(for: .local) == "0 / 7")
        // MQTT is uncapped: a plain count, pluralised, with no "/ N".
        #expect(vm.capacityLabel(for: .mqtt) == "0 channels")
        vm.addChannel(name: "x", kind: .mqtt)
        #expect(vm.capacityLabel(for: .mqtt) == "1 channel")
        vm.addChannel(name: "y", kind: .mqtt)
        #expect(vm.capacityLabel(for: .mqtt) == "2 channels")
    }
}
