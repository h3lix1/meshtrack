@testable import App
import Domain
import Synchronization
import Testing

@Suite("ConnectionSettingsViewModel (broker config + Keychain seam)")
@MainActor
struct ConnectionSettingsViewModelTests {
    /// A seeded secret + its Keychain coordinates.
    private struct SeedPassword {
        let password: String
        let host: String
        let username: String?
    }

    /// The view model under test plus the fakes backing it.
    private struct Harness {
        let model: ConnectionSettingsViewModel
        let gateway: InMemoryConfigGateway
        let credentials: InMemoryCredentialStore
    }

    /// Build a view model over fresh fakes plus a test closure. The closure
    /// records what it was handed so tests can assert the probe inputs.
    private func makeHarness(
        broker: BrokerConfig? = nil,
        seedPassword: SeedPassword? = nil,
        test: @escaping ConnectionTest = { _, _ in .untested }
    ) throws -> Harness {
        let gateway = InMemoryConfigGateway(broker: broker)
        let credentials = InMemoryCredentialStore()
        if let seed = seedPassword {
            try credentials.setPassword(seed.password, host: seed.host, username: seed.username)
        }
        let model = ConnectionSettingsViewModel(
            gateway: gateway,
            credentials: credentials,
            test: test
        )
        return Harness(model: model, gateway: gateway, credentials: credentials)
    }

    // MARK: Load

    @Test
    func `load reads the saved config and password into the fields`() async throws {
        let config = BrokerConfig(
            host: "mqtt.bayme.sh",
            port: 8883,
            username: "meshtrack",
            useTLS: true,
            allowUntrustedCert: false,
            topics: ["msh/US/bayarea/2/e/#"]
        )
        let model = try makeHarness(
            broker: config,
            seedPassword: SeedPassword(password: "hunter2", host: "mqtt.bayme.sh", username: "meshtrack")
        ).model
        try await model.load()
        #expect(model.host == "mqtt.bayme.sh")
        #expect(model.portText == "8883")
        #expect(model.username == "meshtrack")
        #expect(model.useTLS)
        #expect(model.topics == ["msh/US/bayarea/2/e/#"])
        #expect(model.password == "hunter2")
    }

    @Test
    func `load with no saved config falls back to BrokerConfig defaults`() async throws {
        let model = try makeHarness().model
        try await model.load()
        #expect(model.host.isEmpty)
        #expect(model.portText == "8883") // default port
        #expect(model.useTLS) // default TLS on
        #expect(model.topics == [BrokerConfig.defaultTopic])
        #expect(model.password.isEmpty)
    }

    // MARK: Save round-trip

    @Test
    func `save persists the broker config via the gateway`() async throws {
        let harness = try makeHarness()
        let model = harness.model
        try await model.load()
        model.host = "mqtt.example.org"
        model.portText = "1883"
        model.useTLS = false
        model.username = "alice"
        model.topics = ["msh/EU/2/e/#"]
        try await model.save()

        let saved = try #require(try await harness.gateway.loadBrokerConfig())
        #expect(saved.host == "mqtt.example.org")
        #expect(saved.port == 1883)
        #expect(saved.useTLS == false)
        #expect(saved.username == "alice")
        #expect(saved.topics == ["msh/EU/2/e/#"])
        #expect(model.didSave)
    }

    @Test
    func `load then edit then save round-trips through the gateway`() async throws {
        let harness = try makeHarness(
            broker: BrokerConfig(host: "old.host", topics: ["a"])
        )
        let model = harness.model
        try await model.load()
        #expect(model.host == "old.host")
        model.host = "new.host"
        model.addTopic("b")
        try await model.save()

        let saved = try #require(try await harness.gateway.loadBrokerConfig())
        #expect(saved.host == "new.host")
        #expect(saved.topics == ["a", "b"])
    }

    // MARK: Password isolation (the contract: secret never in BrokerConfig)

    @Test
    func `save routes the password to the credential store, never the config`() async throws {
        let harness = try makeHarness()
        let model = harness.model
        try await model.load()
        model.host = "mqtt.example.org"
        model.username = "bob"
        model.password = "s3cret"
        model.topics = ["msh/US/2/e/#"]
        try await model.save()

        // Secret landed in the credential store…
        #expect(harness.credentials.password(host: "mqtt.example.org", username: "bob") == "s3cret")
        // …and is NOT anywhere on the persisted BrokerConfig.
        let saved = try #require(try await harness.gateway.loadBrokerConfig())
        #expect(saved.username == "bob")
        let encoded = String(describing: saved)
        #expect(!encoded.contains("s3cret"))
    }

    @Test
    func `clearing the password removes the stored secret`() async throws {
        let harness = try makeHarness(
            broker: BrokerConfig(host: "mqtt.example.org", username: "bob", topics: ["t"]),
            seedPassword: SeedPassword(password: "s3cret", host: "mqtt.example.org", username: "bob")
        )
        let model = harness.model
        try await model.load()
        #expect(model.password == "s3cret")
        model.password = ""
        try await model.save()
        #expect(harness.credentials.password(host: "mqtt.example.org", username: "bob") == nil)
    }

    // MARK: Topics editor

    @Test
    func `addTopic appends non-empty, de-duplicated topics`() async throws {
        let model = try makeHarness(broker: BrokerConfig(topics: [])).model
        try await model.load()
        model.topics = []
        model.addTopic("msh/US/2/e/#")
        model.addTopic("  ") // blank → ignored
        model.addTopic("msh/US/2/e/#") // dup → ignored
        model.addTopic("msh/EU/2/e/#")
        #expect(model.topics == ["msh/US/2/e/#", "msh/EU/2/e/#"])
    }

    @Test
    func `removeTopic drops the topic at an index, ignoring out-of-range`() async throws {
        let model = try makeHarness(broker: BrokerConfig(topics: ["a", "b", "c"])).model
        try await model.load()
        model.removeTopic(at: 1)
        #expect(model.topics == ["a", "c"])
        model.removeTopic(at: 9) // out of range → no-op
        #expect(model.topics == ["a", "c"])
    }

    // MARK: Connectability

    @Test
    func `isConnectable mirrors BrokerConfig over host and topics`() async throws {
        let model = try makeHarness().model
        try await model.load()
        model.host = ""
        model.topics = ["t"]
        #expect(!model.isConnectable) // no host
        model.host = "h"
        model.topics = []
        #expect(!model.isConnectable) // no topic
        model.topics = ["t"]
        #expect(model.isConnectable)
    }

    // MARK: Test connection

    @Test
    func `testConnection surfaces a success result and forwards the password`() async throws {
        let captured = CapturedProbe()
        let model = try makeHarness { config, password in
            captured.record(config: config, password: password)
            return .success(detail: "\(config.topics.count) topic(s)")
        }.model
        try await model.load()
        model.host = "mqtt.example.org"
        model.username = "bob"
        model.password = "s3cret"
        model.topics = ["msh/US/2/e/#"]
        await model.testConnection()

        #expect(model.testResult == .success(detail: "1 topic(s)"))
        #expect(captured.host == "mqtt.example.org")
        #expect(captured.password == "s3cret") // probe gets the in-memory secret
        // The probed config carries no password (it's a BrokerConfig).
        #expect(captured.configHadNoSecret)
    }

    @Test
    func `testConnection surfaces a failure result`() async throws {
        let model = try makeHarness { _, _ in .failure(reason: "auth rejected") }.model
        try await model.load()
        model.host = "h"
        model.topics = ["t"]
        await model.testConnection()
        #expect(model.testResult == .failure(reason: "auth rejected"))
    }

    @Test
    func `testConnection passes nil password when the field is empty`() async throws {
        let captured = CapturedProbe()
        let model = try makeHarness { config, password in
            captured.record(config: config, password: password)
            return .untested
        }.model
        try await model.load()
        model.host = "h"
        model.password = ""
        model.topics = ["t"]
        await model.testConnection()
        #expect(captured.password == nil)
    }
}

/// Records what the injected probe closure was handed (the closure is `@Sendable`,
/// so this uses a Mutex-backed box).
private final class CapturedProbe: Sendable {
    private struct State {
        var host: String?
        var password: String?
        var configHadNoSecret = true
    }

    private let state = Mutex(State())

    func record(config: BrokerConfig, password: String?) {
        state.withLock {
            $0.host = config.host
            $0.password = password
            // A BrokerConfig has no password field at all; assert the encoded form
            // never leaks the secret we typed.
            if let password { $0.configHadNoSecret = !String(describing: config).contains(password) }
        }
    }

    var host: String? {
        state.withLock { $0.host }
    }

    var password: String? {
        state.withLock { $0.password }
    }

    var configHadNoSecret: Bool {
        state.withLock { $0.configHadNoSecret }
    }
}
