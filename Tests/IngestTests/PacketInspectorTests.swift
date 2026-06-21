import Domain
import Foundation
@testable import Ingest
import MeshProtos
import Testing

@Suite("PacketInspector")
struct PacketInspectorTests {
    private func packet(port: MeshPort, payload: [UInt8], encrypted: Bool = false) -> DecodedPacket {
        DecodedPacket(
            from: 0xA1B2_C3D4, to: 0xFFFF_FFFF, packetID: 42, channel: 8,
            port: port, payload: payload, rxTime: .epoch,
            rxRssi: -90, rxSnr: 5.5, hopStart: 3, hopLimit: 1, wasEncrypted: encrypted
        )
    }

    @Test
    func `summary shows hex ids, broadcast, port, and the lock for encrypted`() {
        let inspection = PacketInspector.inspect(packet(port: .telemetry, payload: [], encrypted: true))
        #expect(inspection.summary.contains("!a1b2c3d4"))
        #expect(inspection.summary.contains("broadcast"))
        #expect(inspection.summary.contains("TELEMETRY"))
        #expect(inspection.summary.contains("🔒"))
    }

    @Test
    func `detail includes provenance and hop count`() {
        let inspection = PacketInspector.inspect(packet(port: .textMessage, payload: [1, 2, 3]))
        #expect(inspection.detail.contains("rssi: -90 dBm"))
        #expect(inspection.detail.contains("snr: 5.5 dB"))
        #expect(inspection.detail.contains("hops: 2/3")) // start 3, limit 1 → 2 hops taken
        #expect(inspection.detail.contains("payload: 3 bytes"))
    }

    @Test
    func `telemetry payload is decoded for display`() throws {
        var metrics = DeviceMetrics()
        metrics.batteryLevel = 88
        metrics.voltage = 3.9
        var telemetry = Telemetry()
        telemetry.deviceMetrics = metrics
        let payload = try [UInt8](telemetry.serializedData())

        let inspection = PacketInspector.inspect(packet(port: .telemetry, payload: payload))
        #expect(inspection.detail.contains("battery: 88%"))
        #expect(inspection.detail.contains(where: { $0.hasPrefix("voltage: 3.9") }))
    }

    @Test
    func `position payload renders coordinates`() throws {
        var position = Position()
        position.latitudeI = 377_749_000
        position.longitudeI = -1_224_194_000
        let payload = try [UInt8](position.serializedData())

        let inspection = PacketInspector.inspect(packet(port: .position, payload: payload))
        #expect(inspection.detail.contains(where: { $0.hasPrefix("lat: 37.77") }))
        #expect(inspection.detail.contains(where: { $0.hasPrefix("lon: -122.41") }))
    }

    @Test
    func `an unmodelled port renders its raw number`() {
        let inspection = PacketInspector.inspect(packet(port: .other(34), payload: []))
        #expect(inspection.summary.contains("PORT(34)"))
    }
}
