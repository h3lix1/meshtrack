// ConnectionSettingsViewModel — presentation logic for the Connection settings
// screen (Phase 8, SPEC §2.5 / §10). This is the proper UI that replaces the
// `MESHTRACK_MQTT_*` environment variables: the broker host/port/TLS/topics and a
// (non-secret) username persist via `ConfigGateway`; the password is a secret and
// flows only through `CredentialStore` (Keychain) — never into `BrokerConfig`,
// never logged.
//
// A testable `@MainActor @Observable` view model over the two injected ports plus a
// `test` closure. The real MQTT probe lives in `Transport`, which `App` cannot
// import, so the lead injects it (see `ConnectionTest` typealias). Unit tests drive
// the in-file fakes below.

import Domain
import Foundation
import Observation
import Synchronization

/// The outcome of a "Test Connection" probe, surfaced to the view. Carries a short
/// human string for success/failure — never any secret material.
public enum ConnectionTestResult: Sendable, Equatable {
    /// No probe has been run yet (the initial / post-edit state).
    case untested
    /// A probe is in flight.
    case testing
    /// The broker accepted the connection. `detail` is a short status (e.g. the
    /// negotiated topic count); it must not contain credentials.
    case success(detail: String)
    /// The probe failed. `reason` is a short, secret-free explanation.
    case failure(reason: String)
}

/// The injected probe the lead supplies: given the (non-secret) `BrokerConfig` and
/// the password (held in memory only for the duration of the probe), attempt a
/// connection and report the result. The real implementation wraps the `Transport`
/// `MQTTAdapter`; `App` can't import `Transport`, hence the injection seam.
public typealias ConnectionTest =
    @Sendable (_ config: BrokerConfig, _ password: String?) async -> ConnectionTestResult

@Observable
@MainActor
public final class ConnectionSettingsViewModel {
    // MARK: Editable fields (bound by the view)

    public var host: String = ""
    public var portText: String = ""
    public var useTLS: Bool = true
    public var allowUntrustedCert: Bool = false
    public var topics: [String] = []
    public var username: String = ""
    /// The password (secret). Held only in memory; persisted via `CredentialStore`
    /// on `save`, never placed in `BrokerConfig`, never logged.
    public var password: String = ""

    /// The result of the most recent "Test Connection" probe.
    public private(set) var testResult: ConnectionTestResult = .untested

    /// Set once `load`/`save` has run successfully (drives a "saved" affordance).
    public private(set) var didSave = false

    @ObservationIgnored private let gateway: any ConfigGateway
    @ObservationIgnored private let credentials: any CredentialStore
    @ObservationIgnored private let test: ConnectionTest

    public init(
        gateway: any ConfigGateway,
        credentials: any CredentialStore,
        test: @escaping ConnectionTest
    ) {
        self.gateway = gateway
        self.credentials = credentials
        self.test = test
    }

    // MARK: Derived

    /// Whether the current edits form a config complete enough to connect — drives
    /// the enabled state of Test / Save. Mirrors `BrokerConfig.isConnectable`.
    public var isConnectable: Bool {
        currentConfig().isConnectable
    }

    /// The parsed port, or `nil` when the text isn't a valid UInt16. Surfaced so the
    /// view can flag an invalid entry.
    public var port: UInt16? {
        UInt16(portText.trimmingCharacters(in: .whitespaces))
    }

    // MARK: Load

    /// Read the saved `BrokerConfig` (or defaults) and the stored password into the
    /// editable fields.
    public func load() async throws {
        let config = try await gateway.loadBrokerConfig() ?? BrokerConfig()
        apply(config)
        password = credentials.password(host: config.host, username: config.username) ?? ""
        testResult = .untested
    }

    private func apply(_ config: BrokerConfig) {
        host = config.host
        portText = String(config.port)
        useTLS = config.useTLS
        allowUntrustedCert = config.allowUntrustedCert
        topics = config.topics
        username = config.username ?? ""
    }

    // MARK: Topics editor

    /// Append a non-empty, de-duplicated topic.
    public func addTopic(_ topic: String) {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !topics.contains(trimmed) else { return }
        topics.append(trimmed)
        testResult = .untested
    }

    /// Remove the topic at `index` if it exists.
    public func removeTopic(at index: Int) {
        guard topics.indices.contains(index) else { return }
        topics.remove(at: index)
        testResult = .untested
    }

    // MARK: Save

    /// Persist the broker config (non-secret) via the gateway and the password via
    /// the credential store. The password is NEVER written into `BrokerConfig`.
    public func save() async throws {
        let config = currentConfig()
        try await gateway.saveBrokerConfig(config)
        // A blank password clears any stored secret for this host/username.
        try credentials.setPassword(
            password.isEmpty ? nil : password,
            host: config.host,
            username: config.username
        )
        didSave = true
    }

    // MARK: Test connection

    /// Run the injected probe against the current edits and surface the result.
    public func testConnection() async {
        testResult = .testing
        testResult = await test(currentConfig(), password.isEmpty ? nil : password)
    }

    // MARK: Config assembly

    /// Build the non-secret `BrokerConfig` from the current edits. The password is
    /// deliberately absent (it is not part of `BrokerConfig`).
    public func currentConfig() -> BrokerConfig {
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        return BrokerConfig(
            host: host.trimmingCharacters(in: .whitespaces),
            port: port ?? (useTLS ? 8883 : 1883),
            username: trimmedUser.isEmpty ? nil : trimmedUser,
            useTLS: useTLS,
            allowUntrustedCert: allowUntrustedCert,
            topics: topics.filter { !$0.isEmpty }
        )
    }
}

// MARK: - In-file fakes (tests + preview)

// `InMemoryConfigGateway` is the shared fake in `SettingsFakes.swift` (one per
// module); this file owns only the credential-store fake below.

/// In-memory `CredentialStore` for tests and previews. Keyed by host + username so
/// multiple brokers/accounts coexist, exactly like the Keychain adapter.
public final class InMemoryCredentialStore: CredentialStore {
    private let passwords = Mutex<[String: String]>([:])

    public init() {}

    private static func key(host: String, username: String?) -> String {
        "\(host)\u{0}\(username ?? "")"
    }

    public func password(host: String, username: String?) -> String? {
        passwords.withLock { $0[Self.key(host: host, username: username)] }
    }

    public func setPassword(_ password: String?, host: String, username: String?) throws {
        let key = Self.key(host: host, username: username)
        passwords.withLock {
            if let password { $0[key] = password } else { $0[key] = nil }
        }
    }
}
