// Test fakes + frame builders for IngestPhase7Tests, split into an extension so the
// test file stays within the lint file/type-body caps.

import Domain
import Foundation
@testable import Ingest
import MeshProtos
import Persistence
import Transport

extension IngestPhase7Tests {
    // MARK: Fakes

    struct StubTransport: MeshTransport {
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

    struct EmptyKeyStore: KeyStore {
        func key(forChannelHash _: UInt32) -> ChannelKey? {
            nil
        }
    }

    struct NoopDecryptor: PacketDecryptor {
        func decrypt(_ c: [UInt8], packetID _: UInt32, fromNode _: UInt32, key _: ChannelKey) -> [UInt8] {
            c
        }
    }

    // MARK: Builders

    func pipeline(_ store: MeshStore) -> IngestPipeline {
        IngestPipeline(
            store: store,
            decoder: PacketDecoder(keyStore: EmptyKeyStore(), decryptor: NoopDecryptor())
        )
    }

    func at(_ seconds: Double) -> Instant {
        Instant.epoch.adding(seconds: seconds)
    }

    func telemetryPayload(battery: UInt32, voltage: Float) -> Data {
        var metrics = DeviceMetrics()
        metrics.batteryLevel = battery
        metrics.voltage = voltage
        var telemetry = Telemetry()
        telemetry.deviceMetrics = metrics
        return try! telemetry.serializedData()
    }

    func telemetryFrame(from: UInt32, packetID: UInt32, at instant: Instant) -> InboundFrame {
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
    func textFrame(
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

    /// A telemetry frame whose firmware `MeshPacket.rxTime` (radio-receipt, whole
    /// seconds since 1970) differs from our frame-receipt instant — so the stored
    /// `rx_time` vs `ingest_time` gap is the real reception→ingest latency, not 0.
    func telemetryFrame(
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

    /// A position frame addressed broadcast, from `from`, via `gateway`.
    func positionFrame(
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

    func telemetryFrame(
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
}
