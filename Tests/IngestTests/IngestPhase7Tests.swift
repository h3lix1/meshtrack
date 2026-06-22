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

    /// A telemetry frame whose firmware `MeshPacket.rxTime` (radio-receipt, whole
    /// seconds since 1970) differs from our frame-receipt instant — so the stored
    /// `rx_time` vs `ingest_time` gap is the real reception→ingest latency, not 0.
    private func telemetryFrame(
        from: UInt32, packetID: UInt32, rxTimeSeconds: UInt32, at instant: Instant
    ) -> InboundFrame {
        var data = DataMessage()
        data.portnum = .telemetryApp
        data.payload = telemetryPayload(battery: 80, voltage: 4.0)
        var packet = MeshPacket()
        packet.from = from
        packet.id = packetID
        packet.channel = 8
        packet.rxTime = rxTimeSeconds
        packet.decoded = data
        var env = ServiceEnvelope()
        env.packet = packet
        env.gatewayID = "!gw1"
        return InboundFrame(
            transport: .mqtt, topic: "msh/US/2/e/MediumFast/!gw1",
            payload: try! [UInt8](env.serializedData()), receivedAt: instant, gatewayID: "!gw1"
        )
    }

    @Test
    func `rx_time comes from MeshPacket rxTime so latency is real, not zero (Finding 4)`() async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        // Firmware stamped rx_time = 100s; we received the frame 5s later, at 105s.
        _ = try await pipeline(store).run(StubTransport(queued: [telemetryFrame(
            from: 7, packetID: 1, rxTimeSeconds: 100, at: at(105)
        )]))
        let times = try await store.writer.read { db -> (rx: Int64, ingest: Int64) in
            let rx = try Int64.fetchOne(db, sql: "SELECT rx_time FROM observation WHERE node_num = 7") ?? -1
            let ingest = try Int64
                .fetchOne(db, sql: "SELECT ingest_time FROM observation WHERE node_num = 7") ?? -1
            return (rx, ingest)
        }
        // rx_time = the firmware's 100s, ingest_time = our 105s frame receipt …
        #expect(times.rx == at(100).nanosecondsSinceEpoch)
        #expect(times.ingest == at(105).nanosecondsSinceEpoch)
        // … so latency (ingest − rx) is a genuine 5 seconds, not ~0.
        let latency = ReceptionLatency(
            rxTime: Instant(nanosecondsSinceEpoch: times.rx),
            ingestTime: Instant(nanosecondsSinceEpoch: times.ingest)
        )
        #expect(latency.seconds == 5)
    }

    @Test
    func `rx_time falls back to frame receipt when MeshPacket rxTime is omitted (Finding 4)`(
    ) async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        // rxTime omitted (0) — fall back to frame receipt; latency collapses to 0.
        _ = try await pipeline(store).run(StubTransport(queued: [telemetryFrame(
            from: 7, packetID: 1, rxTimeSeconds: 0, at: at(42)
        )]))
        let times = try await store.writer.read { db -> (rx: Int64, ingest: Int64) in
            let rx = try Int64.fetchOne(db, sql: "SELECT rx_time FROM observation WHERE node_num = 7") ?? -1
            let ingest = try Int64
                .fetchOne(db, sql: "SELECT ingest_time FROM observation WHERE node_num = 7") ?? -1
            return (rx, ingest)
        }
        #expect(times.rx == at(42).nanosecondsSinceEpoch)
        #expect(times.ingest == at(42).nanosecondsSinceEpoch)
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
    //   • is re-admitted by the fresh in-memory window.
    // The store's DURABLE windowed dedup ledger (`admitExtraction`, schema v6) is
    // what keeps extraction "count once" across runs — proving the durable
    // idempotency these tests assert. Unlike the v5 permanent unique index it
    // replaced (Finding 5), it is bounded to the dedup window, so a legitimate
    // packet-id reuse after the window is recorded, not dropped forever.

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

    // MARK: Windowed (not permanent) extraction dedup (Finding 5)

    @Test
    func `a message re-delivered within the window across a reconnect dedups (Finding 5)`(
    ) async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        // First connection ingests via gw1 at t=0.
        _ = try await pipeline(store).run(StubTransport(queued: [
            textFrame(from: 7, packetID: 99, gateway: "!gw1", body: "hi", at: at(0))
        ]))
        // Reconnect → fresh in-memory DedupWindow; re-delivered via gw2 well inside
        // the 600s window. The DURABLE ledger (not a permanent index) absorbs it.
        let summary = try await pipeline(store).run(StubTransport(queued: [
            textFrame(from: 7, packetID: 99, gateway: "!gw2", body: "hi", at: at(120))
        ]))
        #expect(summary.observationsRecorded == 1) // new gateway = new provenance
        #expect(summary.extractionsDeduped == 0) // fresh window re-admitted …
        #expect(try await store.recentMessages().count == 1) // … but ledger kept it once
    }

    @Test
    func `the same packet identity after the window records a NEW extraction (Finding 5)`(
    ) async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        _ = try await pipeline(store).run(StubTransport(queued: [
            textFrame(from: 7, packetID: 99, gateway: "!gw1", body: "first", at: at(0))
        ]))
        // 601s later the window has elapsed, so a legitimate packet-id reuse is a
        // NEW message — the v5 permanent unique index would have dropped it forever.
        // A different gateway keeps it past the (correct, permanent) observation
        // exact-re-delivery guard, isolating the extraction window under test.
        _ = try await pipeline(store).run(StubTransport(queued: [
            textFrame(from: 7, packetID: 99, gateway: "!gw2", body: "reused", at: at(601))
        ]))
        #expect(try await store.recentMessages().count == 2)
    }

    @Test
    func `two distinct telemetry samples sharing the coarse natural key are both kept (Finding 5)`(
    ) async throws {
        let store = try MeshStore(DatabaseConnection.inMemory())
        // Two DIFFERENT packets from the same node at the same rx_time → same coarse
        // (node_num, t, kind, key) for battery_pct. v5's unique index dropped the
        // second; with v6 the windowed ledger keys on packet identity, so both are kept.
        _ = try await pipeline(store).run(StubTransport(queued: [
            telemetryFrame(from: 7, packetID: 1, gateway: "!gw1", at: at(0)),
            telemetryFrame(from: 7, packetID: 2, gateway: "!gw1", at: at(0))
        ]))
        let battery = try await store.telemetry(forNode: 7).filter { $0.key == "battery_pct" }
        #expect(battery.count == 2) // both samples recorded, not collapsed to one
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
