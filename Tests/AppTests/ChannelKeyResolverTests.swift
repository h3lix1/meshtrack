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

    // MARK: - Registry-aware default fallback (Finding 16)

    @Test
    func `with the default present, default-hash traffic still decodes`() {
        // The default channel is present/enabled, so unknown hashes fall back to the
        // default PSK exactly as before — public default-keyed channels keep decoding.
        let resolver = ChannelKeyResolver(
            primary: RegistryFake(keysByHash: [:]),
            defaultKey: defaultKey,
            defaultEnabled: { true }
        )
        let mediumFastHash = MeshtasticChannelHash.channelHash(
            name: "MediumFast", psk: MeshtasticChannelHash.defaultPSK
        )

        #expect(resolver.key(forChannelHash: mediumFastHash) == defaultKey)
    }

    @Test
    func `after the default is removed, the resolver withholds the default key`() {
        // The operator removed/tombstoned the default channel: the fallback must NOT
        // engage, so default-keyed traffic stops decoding (no silent default decode).
        let mediumFastHash = MeshtasticChannelHash.channelHash(
            name: "MediumFast", psk: MeshtasticChannelHash.defaultPSK
        )
        let resolver = ChannelKeyResolver(
            primary: RegistryFake(keysByHash: [:]),
            defaultKey: defaultKey,
            defaultEnabled: { false }
        )

        #expect(resolver.key(forChannelHash: mediumFastHash) == nil)
        #expect(resolver.key(forChannelHash: 0xDEAD) == nil)
    }

    @Test
    func `removing the default does not block custom-PSK channels from decoding`() {
        // Even with the default fallback withheld, the operator's registered custom
        // PSKs still resolve — only the *default* fallback is gated, not the registry.
        let customPSK = ChannelKey(psk: Array(repeating: 0xAB, count: 16))
        let hash = MeshtasticChannelHash.channelHash(name: "OpsNet", psk: customPSK.psk)
        let resolver = ChannelKeyResolver(
            primary: RegistryFake(keysByHash: [hash: customPSK]),
            defaultKey: defaultKey,
            defaultEnabled: { false }
        )

        #expect(resolver.key(forChannelHash: hash) == customPSK)
        // ...but an unknown hash gets nothing now that the default is gone.
        #expect(resolver.key(forChannelHash: 0xDEAD) == nil)
    }

    @Test
    func `the default gate is read live, so removal takes effect mid-session`() {
        // The signal is a closure read on each lookup, so a same-session removal
        // (the operator deletes the default in Channels & Keys) stops default decode
        // immediately — no resolver rebuild required.
        let enabled = DefaultGate()
        let resolver = ChannelKeyResolver(
            primary: RegistryFake(keysByHash: [:]),
            defaultKey: defaultKey,
            defaultEnabled: { enabled.isOn }
        )
        let hash: UInt32 = 0x1F

        #expect(resolver.key(forChannelHash: hash) == defaultKey)
        enabled.isOn = false
        #expect(resolver.key(forChannelHash: hash) == nil)
    }

    /// A trivial mutable flag, isolated so the `@Sendable` gate closure can read a
    /// value that changes mid-session (modelling the operator toggling the default).
    private final class DefaultGate: @unchecked Sendable {
        var isOn = true
    }
}
