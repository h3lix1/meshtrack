// DataSourceConfig — where the live feed comes from (MQTT broker vs a locally
// attached Meshtastic node over USB-serial or BLE).
//
// This is a SMALL, pure, non-secret selection that sits ALONGSIDE the existing
// `BrokerConfig` rather than inside it: the broker settings keep persisting exactly
// as before (Keychain for the password, `app_config` for the rest), and this adds
// only "which source is active, and — for a local node — which device". `App` is
// snapshot-pure and cannot import `Transport`, so the kind is a plain enum here; the
// composition root (`LiveCoordinator`) maps it onto the real `SerialAdapter` /
// `BLEAdapter`.
//
// Persistence is deliberately decoupled from `ConfigGateway` (which the broker owns)
// via the tiny `DataSourceStore` port below: the production adapter is
// `UserDefaults`-backed (so existing broker persistence is untouched), and an
// in-memory fake serves previews/tests. Nothing here is a secret, so none of it
// touches the Keychain or is ever logged.

import Foundation

/// Which transport feeds the live network. `mqtt` is the original broker path;
/// `serial`/`ble` read a locally attached node.
public enum DataSourceKind: String, Sendable, Equatable, Codable, CaseIterable {
    /// Subscribe to an MQTT broker (the original, default source).
    case mqtt
    /// Read a USB-serial Meshtastic node (`/dev/cu.*`).
    case serial
    /// Read a Meshtastic node over Bluetooth LE.
    case ble
}

/// The persisted data-source selection: the active kind plus the local-node
/// coordinates it needs. Broker settings are NOT duplicated here — when `kind ==
/// .mqtt` the coordinator reads the saved `BrokerConfig`/`CredentialStore` as before.
///
/// - `serialDevicePath` is a `/dev/cu.*` path the user picked/entered (serial only).
/// - `bleDeviceName` is an optional advertised-name filter (BLE only); when empty the
///   adapter connects to the first Meshtastic peripheral it finds.
public struct DataSourceConfig: Sendable, Equatable, Codable {
    public var kind: DataSourceKind
    /// The `/dev/cu.*` device for serial; ignored for other kinds.
    public var serialDevicePath: String
    /// Optional BLE peripheral name filter; ignored for other kinds.
    public var bleDeviceName: String

    public init(
        kind: DataSourceKind = .mqtt,
        serialDevicePath: String = "",
        bleDeviceName: String = ""
    ) {
        self.kind = kind
        self.serialDevicePath = serialDevicePath
        self.bleDeviceName = bleDeviceName
    }

    public static let `default` = DataSourceConfig()

    /// Whether the current selection is complete enough to attempt a connection.
    /// MQTT defers to `BrokerConfig.isConnectable` (checked separately); a serial
    /// source needs a device path; BLE can always attempt a scan.
    public var isConnectable: Bool {
        switch kind {
        case .mqtt: true // gated by BrokerConfig.isConnectable at the call site
        case .serial: !serialDevicePath.trimmingCharacters(in: .whitespaces).isEmpty
        case .ble: true
        }
    }
}

/// Port: loads/saves the (non-secret) data-source selection. Kept separate from
/// `ConfigGateway` so broker persistence is untouched. Production is
/// `UserDefaultsDataSourceStore`; previews/tests use `InMemoryDataSourceStore`.
public protocol DataSourceStore: Sendable {
    func load() -> DataSourceConfig
    func save(_ config: DataSourceConfig)
}

/// `UserDefaults`-backed `DataSourceStore`. Persists one JSON blob under a stable
/// key, so adding fields to `DataSourceConfig` never needs a migration and never
/// disturbs the broker config (which lives in the GRDB `app_config` table).
public struct UserDefaultsDataSourceStore: DataSourceStore {
    // `UserDefaults` is documented thread-safe but is not marked `Sendable`; the
    // store only reads/writes one key, so concurrent access is safe.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = "meshtrack.dataSource"
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> DataSourceConfig {
        guard let data = defaults.data(forKey: key),
              let config = try? JSONDecoder().decode(DataSourceConfig.self, from: data)
        else { return .default }
        return config
    }

    public func save(_ config: DataSourceConfig) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Enumerates candidate serial devices on macOS. The default implementation lists
/// `/dev/cu.*` entries (the call-out side of each TTY, which is what you open to
/// talk to a USB node). Injected so previews/tests stay hermetic.
public protocol SerialDeviceEnumerator: Sendable {
    func availableDevices() -> [String]
}

/// Lists `/dev/cu.*` character devices. Returns an empty list (never throws/crashes)
/// when `/dev` can't be read, so the UI degrades gracefully with no device attached.
public struct POSIXSerialDeviceEnumerator: SerialDeviceEnumerator {
    public init() {}

    public func availableDevices() -> [String] {
        let dev = "/dev"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dev) else {
            return []
        }
        return entries
            .filter { $0.hasPrefix("cu.") }
            .map { "\(dev)/\($0)" }
            .sorted()
    }
}

// MARK: - In-file fakes (tests + previews)

/// In-memory `DataSourceStore` for tests/previews. Thread-confined to the main actor
/// (the only place the Settings UI mutates it), so it needs no lock.
@MainActor
public final class InMemoryDataSourceStore: DataSourceStore {
    private var config: DataSourceConfig

    public init(config: DataSourceConfig = .default) {
        self.config = config
    }

    public nonisolated func load() -> DataSourceConfig {
        MainActor.assumeIsolated { config }
    }

    public nonisolated func save(_ config: DataSourceConfig) {
        MainActor.assumeIsolated { self.config = config }
    }
}

/// A fixed-list `SerialDeviceEnumerator` for previews/tests.
public struct StaticSerialDeviceEnumerator: SerialDeviceEnumerator {
    private let devices: [String]

    public init(devices: [String]) {
        self.devices = devices
    }

    public func availableDevices() -> [String] {
        devices
    }
}
