// LiveDataSource — the resolved, in-memory description of where the live feed comes
// from, and the seam that turns it into a `MeshTransport` for the `LiveCoordinator`.
//
// The Settings UI persists a non-secret `DataSourceConfig` (App) plus the broker's
// `BrokerConfig`/password (ConfigGateway/CredentialStore). This composition-root type
// fuses those into one of three concrete sources and knows how to (a) build the right
// Transport adapter feeding the shared `IngestPipeline`, and (b) name the active
// endpoint for the status indicator — the broker host for MQTT, or the device
// path/name for a locally-attached node. No secret is ever surfaced here.
//
// `App` cannot import `Transport`, so the mapping from `DataSourceKind` onto
// `SerialAdapter`/`BLEAdapter` lives here, in the executable, exactly like the MQTT
// wiring already does.

import App
import Domain
import Transport

/// The resolved live source. Equatable so the coordinator can no-op a reconnect when
/// nothing changed (mirrors the existing `LiveBrokerSettings` comparison). The broker
/// case carries the password in memory; `Equatable` is fine because it never logs.
enum LiveDataSource: Equatable {
    /// Subscribe to an MQTT broker (the original path).
    case mqtt(LiveBrokerSettings)
    /// Read a USB-serial node at `devicePath` (a `/dev/cu.*` entry).
    case serial(devicePath: String)
    /// Read a node over BLE, optionally filtering on advertised `deviceName`.
    case ble(deviceName: String)

    /// The endpoint surfaced to the status indicator (host or device). Never a secret.
    var displayEndpoint: String {
        switch self {
        case let .mqtt(settings): settings.displayHost
        case let .serial(devicePath): devicePath
        case let .ble(deviceName): deviceName.isEmpty ? "BLE node" : deviceName
        }
    }

    /// Build the Transport adapter for this source, feeding the shared pipeline. The
    /// serial/BLE adapters degrade gracefully with no device present (their `frames()`
    /// stream simply finishes — see SerialAdapter/BLEAdapter), so a missing node never
    /// crashes; the status stays `.connecting` until a packet arrives.
    func makeTransport(clock: any Domain.Clock) -> any MeshTransport {
        switch self {
        case let .mqtt(settings):
            MQTTAdapter(config: settings.makeMQTTConfig(), clock: clock)
        case let .serial(devicePath):
            SerialAdapter(devicePath: devicePath, clock: clock)
        case .ble:
            // The current BLEAdapter connects to the first Meshtastic peripheral it
            // finds; the saved name filter is reserved for the HIL bring-up that adds
            // name-based selection. Passing the clock keeps `receivedAt` consistent.
            BLEAdapter(clock: clock)
        }
    }

    /// Resolve the active source from the persisted selection plus the broker config /
    /// password. Returns `nil` when the selection isn't connectable yet (no broker, or
    /// a serial source with no device path) so the caller can stay offline / onboard.
    static func resolve(
        dataSource: DataSourceConfig,
        brokerConfig: BrokerConfig?,
        password: @Sendable (_ host: String, _ username: String?) -> String?
    ) -> LiveDataSource? {
        switch dataSource.kind {
        case .mqtt:
            guard let config = brokerConfig, config.isConnectable else { return nil }
            let secret = password(config.host, config.username)
            return .mqtt(LiveBrokerSettings.from(config: config, password: secret))
        case .serial:
            let path = dataSource.serialDevicePath.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { return nil }
            return .serial(devicePath: path)
        case .ble:
            return .ble(deviceName: dataSource.bleDeviceName.trimmingCharacters(in: .whitespaces))
        }
    }
}
