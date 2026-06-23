// ConnectionSettingsViewModel — presentation logic for the Connection settings
// screen (Phase 8, SPEC §2.5 / §10). This is the proper UI that replaces the
// `MESHTRACK_MQTT_*` environment variables: the broker host/port/TLS/topics and a
// (non-secret) username persist via `ConfigGateway`; the password flows only through
// `CredentialStore` (the local app store) — never into `BrokerConfig`, never logged.
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
    // MARK: Data source (MQTT broker vs locally-attached node)

    /// The active data source. `.mqtt` shows the broker fields below; `.serial`/`.ble`
    /// show the local-node fields. Persisted via `DataSourceStore` on `save`.
    public var dataSourceKind: DataSourceKind = .mqtt
    /// The selected/entered `/dev/cu.*` device path (serial source only).
    public var serialDevicePath: String = ""
    /// Optional BLE peripheral name filter (BLE source only).
    public var bleDeviceName: String = ""

    // MARK: Broker fields (bound by the view; used when `dataSourceKind == .mqtt`)

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
    @ObservationIgnored private let dataSourceStore: any DataSourceStore
    @ObservationIgnored private let serialDevices: any SerialDeviceEnumerator
    /// Bumped on a successful `save()` so the live composition root re-resolves and
    /// (re)connects without a relaunch (Finding 1). Optional — snapshots/tests that
    /// don't wire a live coordinator pass `nil`.
    @ObservationIgnored private let revision: LiveConfigRevision?

    public init(
        gateway: any ConfigGateway,
        credentials: any CredentialStore,
        test: @escaping ConnectionTest,
        dataSourceStore: any DataSourceStore = UserDefaultsDataSourceStore(),
        serialDevices: any SerialDeviceEnumerator = POSIXSerialDeviceEnumerator(),
        revision: LiveConfigRevision? = nil
    ) {
        self.gateway = gateway
        self.credentials = credentials
        self.test = test
        self.dataSourceStore = dataSourceStore
        self.serialDevices = serialDevices
        self.revision = revision
    }

    // MARK: Data-source helpers

    /// The data-source selection assembled from the current edits (non-secret).
    public func currentDataSource() -> DataSourceConfig {
        DataSourceConfig(
            kind: dataSourceKind,
            serialDevicePath: serialDevicePath.trimmingCharacters(in: .whitespaces),
            bleDeviceName: bleDeviceName.trimmingCharacters(in: .whitespaces)
        )
    }

    /// `/dev/cu.*` devices currently visible on the host (empty when none attached).
    /// Re-enumerated on demand so plugging a node in then re-opening the picker shows
    /// it without a relaunch.
    public func availableSerialDevices() -> [String] {
        serialDevices.availableDevices()
    }

    /// Select a data source kind, clearing any stale probe result.
    public func selectDataSource(_ kind: DataSourceKind) {
        guard dataSourceKind != kind else { return }
        dataSourceKind = kind
        testResult = .untested
    }

    // MARK: Derived

    /// Whether the current edits form a config complete enough to connect — drives
    /// the enabled state of Test / Save. For MQTT this mirrors
    /// `BrokerConfig.isConnectable`; for a local node it checks the device selection.
    public var isConnectable: Bool {
        switch dataSourceKind {
        case .mqtt: currentConfig().isConnectable
        case .serial, .ble: currentDataSource().isConnectable
        }
    }

    /// The parsed port, or `nil` when the text isn't a valid UInt16. Surfaced so the
    /// view can flag an invalid entry.
    public var port: UInt16? {
        UInt16(portText.trimmingCharacters(in: .whitespaces))
    }

    // MARK: Load

    /// Read the saved `BrokerConfig` (or defaults), the stored password, and the
    /// saved data-source selection into the editable fields.
    public func load() async throws {
        let config = try await gateway.loadBrokerConfig() ?? BrokerConfig()
        apply(config)
        password = credentials.password(host: config.host, username: config.username) ?? ""
        apply(dataSourceStore.load())
        testResult = .untested
    }

    private func apply(_ source: DataSourceConfig) {
        dataSourceKind = source.kind
        serialDevicePath = source.serialDevicePath
        bleDeviceName = source.bleDeviceName
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

    /// Persist the data-source selection plus the broker config (non-secret) via the
    /// gateway and the password via the credential store. The broker fields persist
    /// exactly as before regardless of the active source, so switching back to MQTT
    /// keeps the saved broker. The password is NEVER written into `BrokerConfig`.
    public func save() async throws {
        dataSourceStore.save(currentDataSource())
        let config = currentConfig()
        try await gateway.saveBrokerConfig(config)
        // A blank password clears any stored secret for this host/username.
        try credentials.setPassword(
            password.isEmpty ? nil : password,
            host: config.host,
            username: config.username
        )
        didSave = true
        // Tell the live composition root the config changed so it reconnects without
        // a relaunch — saving a connectable broker goes live, switching the active
        // source restarts the stream (Finding 1).
        revision?.bump()
    }

    // MARK: Test connection

    /// Run the appropriate check against the current edits and surface the result.
    /// For MQTT this is the injected broker probe; for a local node it is a
    /// device-presence check (the real serial/BLE I/O is hardware-in-the-loop, so the
    /// view model only confirms the device is selectable/visible — connecting happens
    /// at Save). No secret is ever surfaced.
    public func testConnection() async {
        testResult = .testing
        switch dataSourceKind {
        case .mqtt:
            testResult = await test(currentConfig(), password.isEmpty ? nil : password)
        case .serial:
            testResult = serialTestResult()
        case .ble:
            testResult = .success(detail: bleDeviceName.isEmpty
                ? "will scan for the first Meshtastic node over BLE"
                : "will connect to BLE node \"\(bleDeviceName)\"")
        }
    }

    /// Confirm the selected serial device is present (degrades gracefully to a clear
    /// failure when nothing is attached — never a crash).
    private func serialTestResult() -> ConnectionTestResult {
        let path = serialDevicePath.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else {
            return .failure(reason: "select or enter a /dev/cu.* device first")
        }
        let present = availableSerialDevices().contains(path)
            || FileManager.default.fileExists(atPath: path)
        return present
            ? .success(detail: "device present — \(path)")
            : .failure(reason: "no device at \(path) — is the node plugged in?")
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
/// multiple brokers/accounts coexist, exactly like the local `DatabaseCredentialStore`.
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
