import Domain
import Foundation
@testable import Ingest
import MeshProtos
import Persistence
import Testing
import Transport

@Suite("IngestPipeline (decode → provenance → dedup → persist)")
struct IngestPipelineTests {
    // MARK: Fakes

    private struct StubTransport: MeshTransport {
        let queued: [InboundFrame]
        func frames() -> AsyncStream<InboundFrame> {
            AsyncStream { continuation in
                for frame in queued {
                    continuation.yield(frame)
                }
                continuation.finish()
            }
        }
    }

    private struct EmptyKeyStore: KeyStore {
        func key(forChannelHash _: UInt32) -> ChannelKey? {
            nil
        }
    }

    private struct NoopDecryptor: PacketDecryptor {
        func decrypt(_ c: [UInt8], packetID _: UInt32, fromNode _: UInt32, key _: ChannelKey) -> [UInt8] {
            c
        }
    }

    private func pipeline(_ store: MeshStore) -> IngestPipeline {
        IngestPipeline(
            store: store,
            decoder: PacketDecoder(keyStore: EmptyKeyStore(), decryptor: NoopDecryptor())
        )
    }

    private func at(_ seconds: Double) -> Instant {
        Instant.epoch.adding(seconds: seconds)
    }

    /// A plaintext (`.decoded`) frame carrying `data` on `port`, from `from`, via `gateway`.
    private func frame(
        from: UInt32, packetID: UInt32, gateway: String, port: PortNum,
        payload: Data, at instant: Instant
    ) -> InboundFrame {
        var data = DataMessage()
        data.portnum = port
        data.payload = payload
        var packet = MeshPacket()
        packet.from = from
        packet.id = packetID
        packet.channel = 8
        packet.decoded = data
        var env = ServiceEnvelope()
        env.packet = packet
        env.gatewayID = gateway
        let bytes = try! [UInt8](env.serializedData())
        return InboundFrame(
            transport: .mqtt,
            topic: "msh/US/2/e/MediumFast/\(gateway)",
            payload: bytes,
            receivedAt: instant,
            gatewayID: gateway
        )
    }

    private func telemetryPayload(battery: UInt32, voltage: Float) -> Data {
        var metrics = DeviceMetrics()
        metrics.batteryLevel = battery
        metrics.voltage = voltage
        var telemetry = Telemetry()
        telemetry.deviceMetrics = metrics
        return try! telemetry.serializedData()
    }

    private func positionPayload(latI: Int32, lonI: Int32) -> Data {
        var position = Position()
        position.latitudeI = latI
        position.longitudeI = lonI
        return try! position.serializedData()
    }

    // MARK: Tests

    @Test
    func `a telemetry packet persists the node, provenance, and typed telemetry`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        let frames = [frame(
            from: 0xA1B2_C3D4,
            packetID: 1,
            gateway: "!gw1",
            port: .telemetryApp,
            payload: telemetryPayload(battery: 88, voltage: 3.9),
            at: at(10)
        )]
        let summary = try await pipeline(store).run(StubTransport(queued: frames))

        #expect(summary.packetsDecoded == 1)
        #expect(summary.observationsRecorded == 1)
        #expect(summary.telemetryPointsRecorded == 2) // battery_pct + voltage

        #expect(try await store.fetchNode(nodeNum: 0xA1B2_C3D4)?.last_heard_at == at(10)
            .nanosecondsSinceEpoch)
        let series = try await store.telemetry(forNode: 0xA1B2_C3D4)
        #expect(Set(series.map(\.key)) == ["battery_pct", "voltage"])
        #expect(series.first(where: { $0.key == "battery_pct" })?.value == 88)
    }

    @Test
    func `the same packet via two gateways keeps both provenance rows but extracts telemetry once`(
    ) async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        let payload = telemetryPayload(battery: 50, voltage: 4.0)
        let frames = [
            frame(from: 7, packetID: 42, gateway: "!gw1", port: .telemetryApp, payload: payload, at: at(0)),
            frame(from: 7, packetID: 42, gateway: "!gw2", port: .telemetryApp, payload: payload, at: at(1))
        ]
        let summary = try await pipeline(store).run(StubTransport(queued: frames))

        #expect(summary.observationsRecorded == 2) // both gateways = append-only provenance
        #expect(summary.extractionsDeduped == 1) // second is a duplicate
        #expect(summary.telemetryPointsRecorded == 2) // extracted ONCE (not 4)
        #expect(try await store.telemetry(forNode: 7).count == 2)
    }

    @Test
    func `an exact re-delivery (same gateway) is rejected, not double-counted`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        let payload = telemetryPayload(battery: 50, voltage: 4.0)
        let frames = [
            frame(from: 7, packetID: 42, gateway: "!gw1", port: .telemetryApp, payload: payload, at: at(0)),
            frame(from: 7, packetID: 42, gateway: "!gw1", port: .telemetryApp, payload: payload, at: at(0))
        ]
        let summary = try await pipeline(store).run(StubTransport(queued: frames))
        #expect(summary.observationsRecorded == 1)
        #expect(summary.duplicateDeliveriesSkipped == 1)
        #expect(try await store.telemetry(forNode: 7).count == 2)
    }

    @Test
    func `a position packet persists a position fix at the right coordinates`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        let frames = [frame(
            from: 9,
            packetID: 5,
            gateway: "!gw1",
            port: .positionApp,
            payload: positionPayload(latI: 377_749_000, lonI: -1_224_194_000),
            at: at(0)
        )]
        let summary = try await pipeline(store).run(StubTransport(queued: frames))

        #expect(summary.positionFixesRecorded == 1)
        let fixes = try await store.positionFixes(forNode: 9)
        #expect(fixes.count == 1)
        #expect(abs((fixes.first?.lat ?? 0) - 37.7749) < 1e-4)
        #expect(abs((fixes.first?.lon ?? 0) + 122.4194) < 1e-4)
    }

    @Test
    func `a position packet with no GPS fix persists no position (SPEC §2.3)`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        let frames = [frame(
            from: 9,
            packetID: 6,
            gateway: "!gw1",
            port: .positionApp,
            payload: Data(),
            at: at(0)
        )] // empty Position = no lat/lon
        let summary = try await pipeline(store).run(StubTransport(queued: frames))
        #expect(summary.positionFixesRecorded == 0)
        #expect(try await store.positionFixes(forNode: 9).isEmpty)
    }

    @Test
    func `malformed envelope bytes are skipped, not fatal`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        let bad = InboundFrame(
            transport: .mqtt,
            topic: nil,
            payload: [0xFF, 0xFF, 0xFF],
            receivedAt: at(0),
            gatewayID: "!gw1"
        )
        let summary = try await pipeline(store).run(StubTransport(queued: [bad]))
        #expect(summary.decodeErrors == 1)
        #expect(summary.packetsDecoded == 0)
    }
}
