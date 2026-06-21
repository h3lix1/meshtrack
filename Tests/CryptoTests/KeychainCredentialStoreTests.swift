@testable import Crypto
import Domain
import Testing

/// Pure tests for the Keychain `CredentialStore` account-key construction. The
/// live Keychain store/read/delete path is deliberately not unit-tested (no
/// keychain in headless/CI runs — see KeychainCredentialStore.swift), so we test
/// the part that is pure: the `"host|username"` account string that keeps
/// multiple brokers/accounts distinct (SPEC §10).
@Suite("KeychainCredentialStore — account-key construction")
struct KeychainCredentialStoreTests {
    @Test
    func `account joins host and username with a pipe`() {
        #expect(
            KeychainCredentialStore.account(host: "mqtt.meshtastic.org", username: "clive")
                == "mqtt.meshtastic.org|clive"
        )
    }

    @Test
    func `a nil username yields an empty username segment`() {
        #expect(
            KeychainCredentialStore.account(host: "broker.example", username: nil)
                == "broker.example|"
        )
    }

    @Test
    func `anonymous and named accounts on the same host are distinct items`() {
        let anonymous = KeychainCredentialStore.account(host: "h", username: nil)
        let named = KeychainCredentialStore.account(host: "h", username: "u")
        #expect(anonymous != named)
    }

    @Test
    func `different hosts and different usernames produce distinct accounts`() {
        let a = KeychainCredentialStore.account(host: "h1", username: "u")
        let b = KeychainCredentialStore.account(host: "h2", username: "u")
        let c = KeychainCredentialStore.account(host: "h1", username: "v")
        #expect(Set([a, b, c]).count == 3)
    }

    @Test
    func `an empty username is distinct from a nil username only by value, not key shape`() {
        // Both an explicit "" and nil collapse to the same empty segment — the
        // intended behaviour: there is one anonymous slot per host.
        #expect(
            KeychainCredentialStore.account(host: "h", username: "")
                == KeychainCredentialStore.account(host: "h", username: nil)
        )
    }

    @Test
    func `the default service identifier is stable and broker-scoped`() {
        #expect(KeychainCredentialStore.defaultService == "org.meshtrack.broker")
    }

    @Test
    func `KeychainCredentialStore is usable through the CredentialStore port`() {
        // Construction + port conformance compile-check; no Keychain I/O here.
        let store: any CredentialStore = KeychainCredentialStore()
        _ = store
    }
}
