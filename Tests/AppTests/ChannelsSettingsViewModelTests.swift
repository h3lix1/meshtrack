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

    // MARK: - Load

    @Test
    func `load reads channels already present in the store`() async {
        let keys = InMemoryChannelKeyManager()
        let hash = ChannelKeyMath.channelHash(name: "Seeded", psk: ChannelKeyMath.defaultPSK)
        await keys.addChannel(name: "Seeded", hash: hash, kind: .mqtt)
        let vm = ChannelsSettingsViewModel(keys: keys)

        // Nothing until load() runs — the VM does not touch the port in init.
        #expect(vm.mqttChannels.isEmpty)
        await vm.load()
        #expect(vm.mqttChannels.map(\.name) == ["Seeded"])
        #expect(vm.lastError == nil)
    }

    // MARK: - Channel-hash parsing

    @Test
    func `parseChannelHash accepts hex and decimal byte values`() throws {
        #expect(try ChannelKeyMath.parseChannelHash("0x1F") == 0x1F)
        #expect(try ChannelKeyMath.parseChannelHash("0X1f") == 0x1F)
        #expect(try ChannelKeyMath.parseChannelHash("#1f") == 0x1F)
        #expect(try ChannelKeyMath.parseChannelHash("31") == 31)
        #expect(try ChannelKeyMath.parseChannelHash(" 255 ") == 255)
        #expect(try ChannelKeyMath.parseChannelHash("0") == 0)
    }

    @Test
    func `parseChannelHash rejects out-of-range and non-numeric text`() {
        #expect(throws: ChannelsSettingsError.invalidChannelHash) {
            try ChannelKeyMath.parseChannelHash("256") // > one byte
        }
        #expect(throws: ChannelsSettingsError.invalidChannelHash) {
            try ChannelKeyMath.parseChannelHash("0x100") // > one byte
        }
        #expect(throws: ChannelsSettingsError.invalidChannelHash) {
            try ChannelKeyMath.parseChannelHash("nope")
        }
        #expect(throws: ChannelsSettingsError.invalidChannelHash) {
            try ChannelKeyMath.parseChannelHash("-1")
        }
    }

    // MARK: - Add + caps

    @Test
    func `adding with an explicit hash uses the entered byte not the derived one`() async throws {
        let (vm, _) = makeVM()
        await vm.addChannel(name: "Observed", hashText: "0x2A", kind: .mqtt)
        #expect(vm.lastError == nil)
        let entry = try #require(vm.mqttChannels.first)
        #expect(entry.hash == 0x2A)
        // Confirm it did NOT fall back to the name-derived hash.
        let derived = ChannelKeyMath.channelHash(name: "Observed", psk: ChannelKeyMath.defaultPSK)
        #expect(entry.hash != derived || derived == 0x2A)
    }

    @Test
    func `adding with an invalid hash surfaces an error and adds nothing`() async {
        let (vm, _) = makeVM()
        await vm.addChannel(name: "Bad", hashText: "0x100", kind: .mqtt)
        #expect(vm.lastError == .invalidChannelHash)
        #expect(vm.mqttChannels.isEmpty)
    }

    @Test
    func `adding channels splits them into mqtt and local`() async {
        let (vm, _) = makeVM()
        await vm.addChannel(name: "Broker1", kind: .mqtt)
        await vm.addChannel(name: "Device1", kind: .local)
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
    func `mqtt has no cap — the 21st channel is allowed`() async {
        let (vm, _) = makeVM()
        let names = distinctHashNames(21)
        for name in names.prefix(20) {
            await vm.addChannel(name: name, kind: .mqtt)
        }
        #expect(vm.mqttChannels.count == 20)
        #expect(vm.canAdd(.mqtt)) // still room — MQTT is uncapped

        await vm.addChannel(name: names[20], kind: .mqtt)
        #expect(vm.mqttChannels.count == 21)
        #expect(vm.lastError == nil)
        #expect(vm.canAdd(.mqtt))
    }

    @Test
    func `local cap is 7 — the 8th is rejected`() async {
        let (vm, _) = makeVM()
        for i in 0 ..< 7 {
            await vm.addChannel(name: "local-\(i)", kind: .local)
        }
        #expect(vm.localChannels.count == 7)
        #expect(vm.canAdd(.local) == false)

        await vm.addChannel(name: "local-overflow", kind: .local)
        #expect(vm.localChannels.count == 7)
        #expect(vm.lastError == .capacityReached(.local))
    }

    @Test
    func `empty and duplicate names are rejected`() async {
        let (vm, _) = makeVM()
        await vm.addChannel(name: "   ", kind: .mqtt)
        #expect(vm.mqttChannels.isEmpty)
        #expect(vm.lastError == .emptyName)

        await vm.addChannel(name: "dup", kind: .mqtt)
        await vm.addChannel(name: "dup", kind: .mqtt)
        #expect(vm.mqttChannels.count == 1)
        #expect(vm.lastError == .duplicateChannel)
    }

    // MARK: - Set / rotate / clear / delete

    @Test
    func `setting a key flips hasKey and never re-exposes the plaintext`() async throws {
        let (vm, store) = makeVM()
        await vm.addChannel(name: "secure", kind: .mqtt)
        let hash = try #require(vm.mqttChannels.first).hash
        #expect(vm.mqttChannels.first?.hasKey == false)

        await vm.setKey(forChannelHash: hash, pskText: customKeyB64)
        #expect(vm.lastError == nil)
        #expect(vm.mqttChannels.first?.hasKey == true)

        // The view model exposes only a boolean — no API returns the bytes.
        // The store holds the true PSK; the UI's ChannelEntry never does.
        let stored = try #require(await store.storedKey(forChannelHash: hash))
        #expect(stored.psk == [UInt8](Data(base64Encoded: customKeyB64) ?? Data()))
        let entry = try #require(vm.mqttChannels.first)
        // ChannelEntry carries no psk field at all; only hasKey.
        #expect(entry.hasKey == true)
    }

    @Test
    func `rotating a key replaces the stored secret`() async throws {
        let (vm, store) = makeVM()
        await vm.addChannel(name: "rot", kind: .local)
        let hash = try #require(vm.localChannels.first).hash

        await vm.setKey(forChannelHash: hash, pskText: customKeyB64)
        let first = try #require(await store.storedKey(forChannelHash: hash))

        let other = Data(Array(repeating: UInt8(0x77), count: 16)).base64EncodedString()
        await vm.setKey(forChannelHash: hash, pskText: other)
        let second = try #require(await store.storedKey(forChannelHash: hash))

        #expect(first.psk != second.psk)
        #expect(second.psk == [UInt8](Data(base64Encoded: other) ?? Data()))
        #expect(vm.localChannels.first?.hasKey == true)
    }

    @Test
    func `the default-PSK shortcut stores the well-known key`() async throws {
        let (vm, store) = makeVM()
        await vm.addChannel(name: "pub", kind: .mqtt)
        let hash = try #require(vm.mqttChannels.first).hash

        await vm.useDefaultKey(forChannelHash: hash)
        #expect(vm.mqttChannels.first?.hasKey == true)
        #expect(await store.storedKey(forChannelHash: hash)?.psk == ChannelKeyMath.defaultPSK)
    }

    @Test
    func `the AQ text shortcut also stores the default key`() async throws {
        let (vm, store) = makeVM()
        await vm.addChannel(name: "pub2", kind: .mqtt)
        let hash = try #require(vm.mqttChannels.first).hash

        await vm.setKey(forChannelHash: hash, pskText: "AQ==")
        #expect(await store.storedKey(forChannelHash: hash)?.psk == ChannelKeyMath.defaultPSK)
    }

    @Test
    func `clearing a key keeps the channel but drops the secret`() async throws {
        let (vm, store) = makeVM()
        await vm.addChannel(name: "clr", kind: .mqtt)
        let hash = try #require(vm.mqttChannels.first).hash
        await vm.useDefaultKey(forChannelHash: hash)
        #expect(vm.mqttChannels.first?.hasKey == true)

        await vm.clearKey(forChannelHash: hash)
        #expect(vm.mqttChannels.count == 1)
        #expect(vm.mqttChannels.first?.hasKey == false)
        #expect(await store.storedKey(forChannelHash: hash) == nil)
    }

    @Test
    func `deleting a channel removes it and its key`() async throws {
        let (vm, store) = makeVM()
        await vm.addChannel(name: "gone", kind: .local)
        let hash = try #require(vm.localChannels.first).hash
        await vm.useDefaultKey(forChannelHash: hash)

        await vm.removeChannel(hash: hash)
        #expect(vm.localChannels.isEmpty)
        #expect(await store.storedKey(forChannelHash: hash) == nil)
    }

    @Test
    func `an invalid key text surfaces an error and leaves the channel keyless`() async throws {
        let (vm, _) = makeVM()
        await vm.addChannel(name: "bad", kind: .mqtt)
        let hash = try #require(vm.mqttChannels.first).hash

        await vm.setKey(forChannelHash: hash, pskText: "totally not base64 $$$")
        #expect(vm.lastError == .invalidKey)
        #expect(vm.mqttChannels.first?.hasKey == false)
    }

    @Test
    func `capacity label shows local cap and an uncapped mqtt count`() async {
        let (vm, _) = makeVM()
        // Local enforces and shows its 7-channel cap.
        #expect(vm.capacityLabel(for: .local) == "0 / 7")
        // MQTT is uncapped: a plain count, pluralised, with no "/ N".
        #expect(vm.capacityLabel(for: .mqtt) == "0 channels")
        await vm.addChannel(name: "x", kind: .mqtt)
        #expect(vm.capacityLabel(for: .mqtt) == "1 channel")
        await vm.addChannel(name: "y", kind: .mqtt)
        #expect(vm.capacityLabel(for: .mqtt) == "2 channels")
    }
}

/// Auto-derivation of the Meshtastic channel hash from the channel name (Phase 9,
/// T-Channels). A separate suite so the main settings suite stays under the body
/// size cap while these focus on the name → on-wire-hash mapping.
@Suite("ChannelHashDerivation")
@MainActor
struct ChannelHashDerivationTests {
    private func makeVM() -> ChannelsSettingsViewModel {
        ChannelsSettingsViewModel(keys: InMemoryChannelKeyManager())
    }

    @Test
    func `LongFast and MediumFast derive their well-known Meshtastic hashes`() {
        // The public channels hash (name ⊕ index-1 default PSK) to the bytes the
        // firmware advertises: LongFast → 0x08, MediumFast → 0x1F.
        #expect(ChannelKeyMath.channelHash(name: "LongFast", psk: ChannelKeyMath.defaultPSK) == 0x08)
        #expect(ChannelKeyMath.channelHash(name: "MediumFast", psk: ChannelKeyMath.defaultPSK) == 0x1F)
    }

    @Test
    func `derivedHash previews the name-only hash and is nil for an empty name`() {
        let vm = makeVM()
        #expect(vm.derivedHash(forName: "LongFast") == 0x08)
        #expect(vm.derivedHash(forName: "MediumFast") == 0x1F)
        // Whitespace is trimmed before deriving, matching the add path.
        #expect(vm.derivedHash(forName: "  LongFast  ") == 0x08)
        // Nothing to preview until the operator types a name.
        #expect(vm.derivedHash(forName: "") == nil)
        #expect(vm.derivedHash(forName: "   ") == nil)
    }

    @Test
    func `adding by name only derives the Meshtastic hash from the name`() async throws {
        let vm = makeVM()
        // No hash text → the VM derives it from the name with the default PSK.
        await vm.addChannel(name: "MediumFast", kind: .mqtt)
        #expect(vm.lastError == nil)
        let entry = try #require(vm.mqttChannels.first)
        #expect(entry.name == "MediumFast")
        #expect(entry.hash == 0x1F) // well-known MediumFast hash
        #expect(entry.hasKey == false) // starts keyless until a PSK is set

        // And LongFast lands on its own well-known hash, not a collision.
        await vm.addChannel(name: "LongFast", kind: .mqtt)
        #expect(vm.lastError == nil)
        #expect(vm.mqttChannels.map(\.hash) == [0x1F, 0x08])
    }
}
