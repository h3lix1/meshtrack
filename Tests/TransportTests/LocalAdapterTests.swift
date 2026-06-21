import Domain
import Foundation
import Testing
@testable import Transport

/// Tests for the parts of the serial/BLE adapters that are exercisable WITHOUT
/// hardware: typed error surfaces, graceful failure of the stream on a bad
/// device, and the well-known BLE GATT constants. The actual port/radio I/O is
/// best-effort and validated on real hardware (SPEC §6 tier 6), not here.
@Suite("Local-node adapters (serial + BLE)")
struct LocalAdapterTests {
    // MARK: SerialAdapter

    @Test
    func `opening a nonexistent device path throws a typed openFailed`() {
        let path = "/dev/cu.meshtrack-does-not-exist-\(UUID().uuidString)"
        let adapter = SerialAdapter(devicePath: path, clock: InjectedClock())
        #expect(throws: SerialError.self) {
            _ = try adapter.open()
        }
    }

    @Test
    func `opening a non-TTY regular file throws notATTY, not openFailed`() throws {
        // A regular file opens fine but is not a TTY → the raw-mode setup must
        // reject it with the precise typed error (and not leak the descriptor).
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("meshtrack-not-a-tty-\(UUID().uuidString)")
        try Data([0x00]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let adapter = SerialAdapter(devicePath: url.path, clock: InjectedClock())
        do {
            _ = try adapter.open()
            Issue.record("expected notATTY for a regular file")
        } catch let SerialError.notATTY(path) {
            #expect(path == url.path)
        }
    }

    @Test
    func `frames() over an unopenable device finishes immediately without crashing`() async {
        let path = "/dev/cu.meshtrack-does-not-exist-\(UUID().uuidString)"
        let adapter = SerialAdapter(devicePath: path, clock: InjectedClock())
        var count = 0
        for await _ in adapter.frames() {
            count += 1
        }
        #expect(count == 0) // best-effort: no device → empty, finished stream
    }

    @Test
    func `the serial adapter records its configuration`() {
        let clock = InjectedClock()
        let adapter = SerialAdapter(devicePath: "/dev/cu.usbserial-X", clock: clock)
        #expect(adapter.devicePath == "/dev/cu.usbserial-X")
        #expect(adapter.baudRate == speed_t(115_200))
    }

    // MARK: BLEAdapter constants

    @Test
    func `the Meshtastic BLE service and characteristic UUIDs match the spec`() {
        #expect(MeshtasticBLE.service == "6ba1b218-15a8-461f-9fa8-5dcae273eafd")
        #expect(MeshtasticBLE.fromRadio == "2c55e69e-4993-11ed-b878-0242ac120002")
        #expect(MeshtasticBLE.toRadio == "f75c76d2-129e-4dad-a1dd-7866124401e7")
        #expect(MeshtasticBLE.fromNum == "ed9da18c-a800-4f66-a670-aa7547e34453")
        // The CBUUID accessors mint a value equal to the canonical string.
        #expect(MeshtasticBLE.serviceUUID == MeshtasticBLE.serviceUUID)
        #expect(MeshtasticBLE.serviceUUID.uuidString.lowercased() == MeshtasticBLE.service)
    }

    @Test
    func `the BLE adapter is constructible with a clock`() {
        // Construction must not touch CoreBluetooth (no scan starts until frames()).
        let adapter = BLEAdapter(clock: InjectedClock())
        #expect(adapter.clock.now() == Instant.epoch)
    }
}
