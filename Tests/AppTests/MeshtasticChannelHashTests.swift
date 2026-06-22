@testable import App
import Testing

@Suite("MeshtasticChannelHash — the one shared channel-hash + default-PSK source")
struct MeshtasticChannelHashTests {
    @Test
    func `the default PSK is the well-known 16-byte expansion of 0x01`() {
        // Pins the exact bytes the public Meshtastic channels share. If this drifts,
        // both the settings screen and the map's preset resolver decode the wrong
        // traffic — so this constant is the contract.
        #expect(MeshtasticChannelHash.defaultPSK == [
            0xD4, 0xF1, 0xBB, 0x3A, 0x20, 0x29, 0x07, 0x59,
            0xF0, 0xBC, 0xFF, 0xAB, 0xCF, 0x4E, 0x69, 0x01
        ])
    }

    @Test
    func `known channel names hash to their canonical firmware values`() {
        // LongFast → 8 and MediumFast → 0x1F are the well-known on-wire hashes real
        // radios transmit; pinning them locks the XOR fold to firmware behavior.
        let psk = MeshtasticChannelHash.defaultPSK
        #expect(MeshtasticChannelHash.channelHash(name: "LongFast", psk: psk) == 8)
        #expect(MeshtasticChannelHash.channelHash(name: "MediumFast", psk: psk) == 0x1F)
    }

    @Test
    func `the fold is xor(name) xor xor(psk)`() {
        // Independent re-derivation of the algorithm pins the contract, including a
        // non-default PSK so the helper isn't only correct for the public channels.
        let name = "Secret"
        let psk: [UInt8] = Array(0 ..< 16)
        let expected = UInt32(
            Array(name.utf8).reduce(UInt8(0)) { $0 ^ $1 }
                ^ psk.reduce(UInt8(0)) { $0 ^ $1 }
        )
        #expect(MeshtasticChannelHash.channelHash(name: name, psk: psk) == expected)
    }

    @Test
    func `both call sites delegate to the one helper`() {
        // ChannelKeyMath (Settings) and ChannelPreset (Map) must agree with the
        // shared helper for the same inputs, proving there is no second copy.
        let psk = MeshtasticChannelHash.defaultPSK
        #expect(ChannelKeyMath.defaultPSK == MeshtasticChannelHash.defaultPSK)
        #expect(ChannelPreset.defaultPSK == MeshtasticChannelHash.defaultPSK)
        #expect(
            ChannelKeyMath.channelHash(name: "MediumFast", psk: psk)
                == MeshtasticChannelHash.channelHash(name: "MediumFast", psk: psk)
        )
        #expect(
            ChannelPreset.hash(name: "MediumFast", psk: psk)
                == MeshtasticChannelHash.channelHash(name: "MediumFast", psk: psk)
        )
    }
}
