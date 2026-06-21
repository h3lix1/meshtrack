@testable import App
import Domain
import Synchronization
import Testing

/// Data-source behavior of `ConnectionSettingsViewModel`: selecting MQTT vs a local
/// node, persisting the choice, and the local-node "Test Connection" path (which is a
/// device-presence check, not the MQTT probe). Split from
/// `ConnectionSettingsViewModelTests` to keep each suite within the type-body budget.
@Suite("ConnectionSettingsViewModel (data source: MQTT vs local node)")
@MainActor
struct ConnectionSettingsDataSourceTests {
    private struct Harness {
        let model: ConnectionSettingsViewModel
        let gateway: InMemoryConfigGateway
        let dataSource: InMemoryDataSourceStore
    }

    private func makeHarness(
        broker: BrokerConfig? = nil,
        dataSource: DataSourceConfig = .default,
        serialDevices: [String] = [],
        test: @escaping ConnectionTest = { _, _ in .untested }
    ) -> Harness {
        let gateway = InMemoryConfigGateway(broker: broker)
        let dataSourceStore = InMemoryDataSourceStore(config: dataSource)
        let model = ConnectionSettingsViewModel(
            gateway: gateway,
            credentials: InMemoryCredentialStore(),
            test: test,
            dataSourceStore: dataSourceStore,
            serialDevices: StaticSerialDeviceEnumerator(devices: serialDevices)
        )
        return Harness(model: model, gateway: gateway, dataSource: dataSourceStore)
    }

    // MARK: Load / save

    @Test
    func `load reads the saved data source and device into the fields`() async throws {
        let model = makeHarness(
            dataSource: DataSourceConfig(kind: .serial, serialDevicePath: "/dev/cu.usbmodem3101")
        ).model
        try await model.load()
        #expect(model.dataSourceKind == .serial)
        #expect(model.serialDevicePath == "/dev/cu.usbmodem3101")
    }

    @Test
    func `save persists the data source alongside the broker config`() async throws {
        let harness = makeHarness()
        let model = harness.model
        try await model.load()
        // Keep a valid broker AND switch the active source to serial.
        model.host = "mqtt.example.org"
        model.topics = ["msh/US/2/e/#"]
        model.selectDataSource(.serial)
        model.serialDevicePath = "/dev/cu.usbserial-0001"
        try await model.save()

        let savedSource = harness.dataSource.load()
        #expect(savedSource.kind == .serial)
        #expect(savedSource.serialDevicePath == "/dev/cu.usbserial-0001")
        // The broker config is still persisted (switching back to MQTT keeps it).
        let savedBroker = try #require(try await harness.gateway.loadBrokerConfig())
        #expect(savedBroker.host == "mqtt.example.org")
    }

    @Test
    func `selectDataSource swaps the kind and clears a stale probe result`() async throws {
        let model = makeHarness(test: { _, _ in .success(detail: "ok") }).model
        try await model.load()
        model.host = "h"
        model.topics = ["t"]
        await model.testConnection()
        #expect(model.testResult == .success(detail: "ok"))
        model.selectDataSource(.serial)
        #expect(model.dataSourceKind == .serial)
        #expect(model.testResult == .untested)
    }

    // MARK: Connectability

    @Test
    func `isConnectable for serial requires a device path`() async throws {
        let model = makeHarness().model
        try await model.load()
        model.selectDataSource(.serial)
        #expect(!model.isConnectable) // no device path yet
        model.serialDevicePath = "/dev/cu.usbserial-0001"
        #expect(model.isConnectable)
    }

    @Test
    func `isConnectable for ble is always true`() async throws {
        let model = makeHarness().model
        try await model.load()
        model.selectDataSource(.ble)
        #expect(model.isConnectable) // a scan can always be attempted
    }

    // MARK: Test connection (local node = device-presence, never the MQTT probe)

    @Test
    func `testConnection for serial reports a missing device gracefully`() async throws {
        let model = makeHarness(serialDevices: []).model
        try await model.load()
        model.selectDataSource(.serial)
        model.serialDevicePath = "/dev/cu.absent-device-xyz"
        await model.testConnection()
        if case let .failure(reason) = model.testResult {
            #expect(reason.contains("no device"))
        } else {
            Issue.record("expected a graceful failure for a missing device")
        }
    }

    @Test
    func `testConnection for serial reports a present device`() async throws {
        let device = "/dev/cu.usbmodem3101"
        let model = makeHarness(serialDevices: [device]).model
        try await model.load()
        model.selectDataSource(.serial)
        model.serialDevicePath = device
        await model.testConnection()
        if case let .success(detail) = model.testResult {
            #expect(detail.contains(device))
        } else {
            Issue.record("expected success for a present device")
        }
    }

    @Test
    func `testConnection for ble surfaces a scan/connect plan, never a secret`() async throws {
        let model = makeHarness().model
        try await model.load()
        model.selectDataSource(.ble)
        await model.testConnection()
        #expect(model.testResult == .success(detail: "will scan for the first Meshtastic node over BLE"))
        model.bleDeviceName = "Meshtastic_1a2b"
        await model.testConnection()
        #expect(model.testResult == .success(detail: "will connect to BLE node \"Meshtastic_1a2b\""))
    }

    @Test
    func `serial probe does not invoke the MQTT broker probe closure`() async throws {
        let probed = ProbeFlag()
        let model = makeHarness(serialDevices: ["/dev/cu.usbmodem3101"], test: { _, _ in
            probed.mark()
            return .success(detail: "broker")
        }).model
        try await model.load()
        model.selectDataSource(.serial)
        model.serialDevicePath = "/dev/cu.usbmodem3101"
        await model.testConnection()
        #expect(!probed.ran) // the MQTT probe must not have run
    }
}

/// Records whether the injected (MQTT) probe closure was invoked. `@Sendable`, so a
/// `Mutex`-backed flag.
private final class ProbeFlag: Sendable {
    private let state = Mutex(false)
    func mark() {
        state.withLock { $0 = true }
    }

    var ran: Bool {
        state.withLock { $0 }
    }
}
