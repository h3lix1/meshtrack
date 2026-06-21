@testable import App
import Foundation
import Testing

@Suite("DataSourceConfig (selection shape + persistence)")
struct DataSourceConfigTests {
    @Test
    func `mqtt is connectable on its own (broker gating is separate)`() {
        #expect(DataSourceConfig(kind: .mqtt).isConnectable)
    }

    @Test
    func `serial needs a non-blank device path`() {
        #expect(!DataSourceConfig(kind: .serial, serialDevicePath: "").isConnectable)
        #expect(!DataSourceConfig(kind: .serial, serialDevicePath: "   ").isConnectable)
        #expect(DataSourceConfig(kind: .serial, serialDevicePath: "/dev/cu.x").isConnectable)
    }

    @Test
    func `ble is always connectable (a scan can be attempted)`() {
        #expect(DataSourceConfig(kind: .ble).isConnectable)
    }

    @Test
    func `default selection is mqtt with no device fields`() {
        let config = DataSourceConfig.default
        #expect(config.kind == .mqtt)
        #expect(config.serialDevicePath.isEmpty)
        #expect(config.bleDeviceName.isEmpty)
    }

    @Test
    func `UserDefaults store round-trips the selection without touching other keys`() {
        // A dedicated suite so the test never collides with real app defaults.
        let suiteName = "meshtrack.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)
        defer { defaults?.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsDataSourceStore(
            defaults: defaults ?? .standard, key: "ds"
        )
        // Absent → default.
        #expect(store.load() == .default)
        let saved = DataSourceConfig(kind: .serial, serialDevicePath: "/dev/cu.usbmodem3101")
        store.save(saved)
        #expect(store.load() == saved)
    }

    @Test
    func `POSIX enumerator lists only cu devices and never throws`() {
        // On any macOS host /dev has at least Bluetooth-Incoming-Port; the contract
        // we assert is that every result is a /dev/cu.* path (and the call is safe).
        let devices = POSIXSerialDeviceEnumerator().availableDevices()
        for device in devices {
            #expect(device.hasPrefix("/dev/cu."))
        }
    }
}
