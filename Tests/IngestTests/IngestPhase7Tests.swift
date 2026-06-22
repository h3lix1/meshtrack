import Domain
import Foundation
import GRDB
@testable import Ingest
import MeshProtos
import Persistence
import Synchronization
import Testing
import Transport

@Suite("IngestPipeline — Phase 7 (ingest_time, messages, onDecoded tap)")
struct IngestPhase7Tests {
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

    private func telemetryPayload(battery: UInt32, voltage: Float) -> Data {
        var metrics = DeviceMetrics()
        metrics.batteryLevel = battery
        metrics.voltage = voltage
        var telemetry = Telemetry()
        telemetry.deviceMetrics = metrics
        return try! telemetry.serializedData()
    }

    private func telemetryFrame(from: UInt32, packetID: UInt32, at instant: Instant) -> InboundFrame {
        var data = DataMessage()
        data.portnum = .telemetryApp
        data.payload = telemetryPayload(battery: 80, voltage: 4.0)
        var packet = MeshPacket()
        packet.from = from
        packet.id = packetID
        packet.channel = 8
        packet.decoded = data
        var env = ServiceEnvelope()
        env.packet = packet
        env.gatewayID = "!gw1"
        return InboundFrame(
            transport: .mqtt, topic: "msh/US/2/e/MediumFast/!gw1",
            payload: try! [UInt8](env.serializedData()), receivedAt: instant, gatewayID: "!gw1"
        )
    }

    /// A text-message frame addressed to `to` (default broadcast).
    private func textFrame(
        from: UInt32, packetID: UInt32, gateway: String, body: String,
        to: UInt32 = 0xFFFF_FFFF, at instant: Instant
    ) -> InboundFrame {
        var data = DataMessage()
        data.portnum = .textMessageApp
        data.payload = Data(body.utf8)
        var packet = MeshPacket()
        packet.from = from
        packet.to = to
        packet.id = packetID
        packet.channel = 8
        packet.decoded = data
        var env = ServiceEnvelope()
        env.packet = packet
        env.gatewayID = gateway
        return InboundFrame(
            transport: .mqtt, topic: "msh/US/2/e/MediumFast/\(gateway)",
            payload: try! [UInt8](env.serializedData()), receivedAt: instant, gatewayID: gateway
        )
    }

    // MARK: Tests

    @Test
    func `every observation records ingest_time for latency (SPEC §2.11)`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        _ = try await pipeline(store).run(StubTransport(queued: [telemetryFrame(
            from: 7,
            packetID: 1,
            at: at(10)
        )]))
        let ingest = try await store.writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT ingest_time FROM observation WHERE node_num = 7")
        }
        #expect(ingest == at(10).nanosecondsSinceEpoch)
    }

    @Test
    func `a text message decodes into the message store, counted once per dedup key`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        let frames = [
            textFrame(from: 7, packetID: 1, gateway: "!gw1", body: "hello @SFGate", at: at(0)),
            // same packet via a second gateway → provenance kept, message deduped.
            textFrame(from: 7, packetID: 1, gateway: "!gw2", body: "hello @SFGate", at: at(1))
        ]
        let summary = try await pipeline(store).run(StubTransport(queued: frames))

        #expect(summary.observationsRecorded == 2)
        #expect(summary.extractionsDeduped == 1)
        #expect(summary.messagesRecorded == 1) // extracted ONCE

        let messages = try await store.recentMessages()
        #expect(messages.count == 1)
        #expect(messages.first?.body == "hello @SFGate")
        #expect(messages.first?.channel == 8)
        #expect(messages.first?.channel_name == "MediumFast") // parsed from the topic
        #expect(messages.first?.is_dm == false) // broadcast
    }

    @Test
    func `a direct text message is flagged is_dm`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        let frames = [textFrame(from: 7, packetID: 2, gateway: "!gw1", body: "psst", to: 99, at: at(0))]
        let summary = try await pipeline(store).run(StubTransport(queued: frames))
        #expect(summary.messagesRecorded == 1)
        let messages = try await store.recentMessages()
        #expect(messages.first?.is_dm == true)
        #expect(messages.first?.to_num == 99)
    }

    @Test
    func `an empty text body records no message`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        let frames = [textFrame(from: 7, packetID: 3, gateway: "!gw1", body: "", at: at(0))]
        let summary = try await pipeline(store).run(StubTransport(queued: frames))
        #expect(summary.packetsDecoded == 1)
        #expect(summary.messagesRecorded == 0)
        #expect(try await store.recentMessages().isEmpty)
    }

    /// A position frame addressed broadcast, from `from`, via `gateway`.
    private func positionFrame(
        from: UInt32, packetID: UInt32, gateway: String, latI: Int32, lonI: Int32, at instant: Instant
    ) -> InboundFrame {
        var position = Position()
        position.latitudeI = latI
        position.longitudeI = lonI
        var data = DataMessage()
        data.portnum = .positionApp
        data.payload = (try? position.serializedData()) ?? Data()
        var packet = MeshPacket()
        packet.from = from
        packet.id = packetID
        packet.channel = 8
        packet.decoded = data
        var env = ServiceEnvelope()
        env.packet = packet
        env.gatewayID = gateway
        return InboundFrame(
            transport: .mqtt, topic: "msh/US/2/e/MediumFast/\(gateway)",
            payload: (try? [UInt8](env.serializedData())) ?? [], receivedAt: instant, gatewayID: gateway
        )
    }

    private func telemetryFrame(
        from: UInt32, packetID: UInt32, gateway: String, at instant: Instant
    ) -> InboundFrame {
        var data = DataMessage()
        data.portnum = .telemetryApp
        data.payload = telemetryPayload(battery: 80, voltage: 4.0)
        var packet = MeshPacket()
        packet.from = from
        packet.id = packetID
        packet.channel = 8
        packet.decoded = data
        var env = ServiceEnvelope()
        env.packet = packet
        env.gatewayID = gateway
        return InboundFrame(
            transport: .mqtt, topic: "msh/US/2/e/MediumFast/\(gateway)",
            payload: (try? [UInt8](env.serializedData())) ?? [], receivedAt: instant, gatewayID: gateway
        )
    }

    // MARK: Reconnect-then-redeliver idempotency (Finding 2)

    //
    // A reconnect/config change starts a FRESH `run()` with a brand-new
    // in-memory `DedupWindow`, and observation dedup is gateway-scoped. So the
    // same packet re-delivered via a DIFFERENT gateway after a reconnect:
    //   • passes observation dedup (new gateway = new provenance row), and
    //   • is re-admitted by the fresh window.
    // The store's v5 unique indexes are the only thing that keeps extraction
    // "count once" — proving the durable idempotency these tests assert.

    @Test
    func `a message re-delivered via a different gateway after a reconnect is not duplicated`(
    ) async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        // First connection: ingest via gw1.
        _ = try await pipeline(store).run(StubTransport(queued: [
            textFrame(from: 7, packetID: 99, gateway: "!gw1", body: "hello", at: at(0))
        ]))
        // Reconnect → a NEW run() (fresh DedupWindow) re-delivers via gw2.
        let summary = try await pipeline(store).run(StubTransport(queued: [
            textFrame(from: 7, packetID: 99, gateway: "!gw2", body: "hello", at: at(1))
        ]))

        // New gateway = a new provenance row, and the fresh window re-admitted it …
        #expect(summary.observationsRecorded == 1)
        #expect(summary.extractionsDeduped == 0)
        // … but the store ignored the duplicate, so there is still ONE message.
        #expect(try await store.recentMessages().count == 1)
    }

    @Test
    func `telemetry re-delivered via a different gateway after a reconnect is not double-counted`(
    ) async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        _ = try await pipeline(store).run(StubTransport(queued: [
            telemetryFrame(from: 7, packetID: 99, gateway: "!gw1", at: at(0))
        ]))
        // Same rx_time so the natural key (node_num, t, kind, key) matches.
        _ = try await pipeline(store).run(StubTransport(queued: [
            telemetryFrame(from: 7, packetID: 99, gateway: "!gw2", at: at(0))
        ]))
        // battery_pct + voltage, recorded exactly once (not 4 rows).
        #expect(try await store.telemetry(forNode: 7).count == 2)
    }

    @Test
    func `a position re-delivered via a different gateway after a reconnect is not duplicated`(
    ) async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        _ = try await pipeline(store).run(StubTransport(queued: [
            positionFrame(
                from: 7,
                packetID: 99,
                gateway: "!gw1",
                latI: 377_749_000,
                lonI: -1_224_194_000,
                at: at(0)
            )
        ]))
        _ = try await pipeline(store).run(StubTransport(queued: [
            positionFrame(
                from: 7,
                packetID: 99,
                gateway: "!gw2",
                latI: 377_749_000,
                lonI: -1_224_194_000,
                at: at(0)
            )
        ]))
        #expect(try await store.positionFixes(forNode: 7).count == 1)
    }

    @Test
    func `onDecoded fires once per decoded packet for the live trace feed`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        let frames = [
            telemetryFrame(from: 7, packetID: 1, at: at(0)),
            textFrame(from: 8, packetID: 2, gateway: "!gw1", body: "hi", at: at(1)),
            // a malformed frame must NOT invoke the tap.
            InboundFrame(transport: .mqtt, topic: nil, payload: [0xFF], receivedAt: at(2), gatewayID: "!gw1")
        ]
        let seen = Mutex<[UInt32]>([])
        let summary = try await pipeline(store).run(StubTransport(queued: frames)) { packet in
            seen.withLock { $0.append(packet.from) }
        }
        #expect(summary.packetsDecoded == 2)
        #expect(seen.withLock { $0 } == [7, 8])
    }
}
