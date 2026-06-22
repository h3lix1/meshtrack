@testable import App
import Domain
import Testing

@Suite("ChannelKeyResolver — custom PSK by hash, default-PSK fallback")
struct ChannelKeyResolverTests {
    /// A stand-in for the live Keychain channel registry: holds per-channel PSKs
    /// keyed by channel hash, exactly the shape `KeychainKeyStore` presents to the
    /// resolver. Returns `nil` for an unregistered hash so the fallback engages.
    private struct RegistryFake: KeyStore {
        let keysByHash: [UInt32: ChannelKey]
        func key(forChannelHash channelHash: UInt32) -> ChannelKey? {
            keysByHash[channelHash]
        }
    }

    private let defaultKey = ChannelKey(psk: MeshtasticChannelHash.defaultPSK)

    @Test
    func `a custom-PSK channel is resolved by its hash`() {
        // The operator registered a custom-PSK channel in Channels & Keys; the live
        // resolver must hand that PSK to the decoder for the channel's hash, NOT the
        // default — this is the Finding 8 bug (every hash got the default before).
        let customPSK = ChannelKey(psk: Array(repeating: 0xAB, count: 16))
        let name = "OpsNet"
        let hash = MeshtasticChannelHash.channelHash(name: name, psk: customPSK.psk)
        let resolver = ChannelKeyResolver(
            primary: RegistryFake(keysByHash: [hash: customPSK]),
            defaultKey: defaultKey
        )

        #expect(resolver.key(forChannelHash: hash) == customPSK)
        #expect(resolver.key(forChannelHash: hash) != defaultKey)
    }

    @Test
    func `an unknown hash falls back to the default PSK`() {
        // A public/default channel (no custom PSK registered) still decodes: the
        // resolver returns the well-known default key for any hash the registry
        // doesn't hold.
        let resolver = ChannelKeyResolver(
            primary: RegistryFake(keysByHash: [:]),
            defaultKey: defaultKey
        )
        let mediumFastHash = MeshtasticChannelHash.channelHash(
            name: "MediumFast", psk: MeshtasticChannelHash.defaultPSK
        )

        #expect(resolver.key(forChannelHash: mediumFastHash) == defaultKey)
        #expect(resolver.key(forChannelHash: 0xDEAD) == defaultKey)
    }

    @Test
    func `the registry takes precedence over the default for the same hash`() {
        // If a custom PSK happens to be registered under a hash that also matches a
        // public preset, the operator's key wins — the registry is consulted first.
        let custom = ChannelKey(psk: Array(repeating: 0x11, count: 32))
        let hash: UInt32 = 0x1F
        let resolver = ChannelKeyResolver(
            primary: RegistryFake(keysByHash: [hash: custom]),
            defaultKey: defaultKey
        )

        #expect(resolver.key(forChannelHash: hash) == custom)
    }
}
