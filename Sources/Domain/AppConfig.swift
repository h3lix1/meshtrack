// App configuration contracts (Phase 8) — the persisted settings that drive the app
// + collector, plus the effect ports that store them. These are the shared contracts
// the Settings UI and the persistence adapters all code against, so configuration
// moves out of environment variables and into proper screens (SPEC §2.5/§10).
//
// Pure: Domain owns the value types and the ports; the GRDB implementations
// (`ConfigGateway`, `DatabaseKeyStore`, `DatabaseCredentialStore`) live in the outer
// ring (Persistence). Secrets here are already-public broker/channel keys, stored
// locally alongside the rest of the config rather than the system Keychain.

/// MQTT broker connection settings. The password is NOT here — it is stored
/// separately via `CredentialStore` (the local `app_config` store), keyed by host +
/// username. The username is treated as non-secret (routinely visible).
public struct BrokerConfig: Sendable, Equatable, Codable {
    public var host: String
    public var port: UInt16
    public var username: String?
    public var useTLS: Bool
    public var allowUntrustedCert: Bool
    /// Subscribe topics (e.g. `msh/US/bayarea/2/e/#`). At least one to go live.
    public var topics: [String]
    /// Stable MQTT client id; empty → the adapter generates one.
    public var clientID: String

    public static let defaultTopic = "msh/US/bayarea/2/e/#"

    public init(
        host: String = "",
        port: UInt16 = 8883,
        username: String? = nil,
        useTLS: Bool = true,
        allowUntrustedCert: Bool = false,
        topics: [String] = [BrokerConfig.defaultTopic],
        clientID: String = ""
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.useTLS = useTLS
        self.allowUntrustedCert = allowUntrustedCert
        self.topics = topics
        self.clientID = clientID
    }

    /// Whether this config is complete enough to attempt a connection.
    public var isConnectable: Bool {
        !host.isEmpty && !topics.filter { !$0.isEmpty }.isEmpty
    }
}

/// Non-secret application preferences. Persisted in the shared store; editable from
/// the General settings screen.
public struct AppSettings: Sendable, Equatable, Codable {
    /// Cadence (seconds) of the slow "surface newly-positioned nodes" refresh loop.
    public var refreshIntervalSeconds: Double
    /// Selected theme identifier (see the App theme customizer); `nil` = default.
    public var themeID: String?
    /// Metric vs imperial display units.
    public var useMetricUnits: Bool
    /// How long raw telemetry is retained before rollup-only (days).
    public var telemetryRetentionDays: Int
    /// macOS notification delivery toggle.
    public var notificationsEnabled: Bool
    /// Launch the collector at login (LaunchAgent).
    public var startAtLogin: Bool
    /// Connect to the configured broker automatically on launch.
    public var autoConnect: Bool

    public init(
        refreshIntervalSeconds: Double = 3,
        themeID: String? = nil,
        useMetricUnits: Bool = true,
        telemetryRetentionDays: Int = 30,
        notificationsEnabled: Bool = true,
        startAtLogin: Bool = false,
        autoConnect: Bool = true
    ) {
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.themeID = themeID
        self.useMetricUnits = useMetricUnits
        self.telemetryRetentionDays = telemetryRetentionDays
        self.notificationsEnabled = notificationsEnabled
        self.startAtLogin = startAtLogin
        self.autoConnect = autoConnect
    }

    public static let `default` = AppSettings()
}

/// Port: loads/saves the broker/app configuration. Production is GRDB-backed
/// (`MeshStore` in Persistence); tests/previews use an in-memory fake. The broker
/// password flows through `CredentialStore`, not here.
public protocol ConfigGateway: Sendable {
    /// The saved broker config, or `nil` if none has been configured yet.
    func loadBrokerConfig() async throws -> BrokerConfig?
    func saveBrokerConfig(_ config: BrokerConfig) async throws
    /// The saved app settings, or the defaults if none have been saved.
    func loadAppSettings() async throws -> AppSettings
    func saveAppSettings(_ settings: AppSettings) async throws
}

/// Port: stores the broker password in the local app store, keyed by broker host +
/// username so multiple brokers/accounts coexist. Production is `DatabaseCredentialStore`
/// (the `app_config` table); the passwords for the public brokers this app targets are
/// already published, so they live with the rest of the config. Never logged.
public protocol CredentialStore: Sendable {
    func password(host: String, username: String?) -> String?
    func setPassword(_ password: String?, host: String, username: String?) throws
}
