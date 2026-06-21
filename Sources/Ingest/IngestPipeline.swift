// IngestPipeline — decode → provenance → dedup → persist (SPEC §2.2/§2.4/§5).
//
// Consumes a MeshTransport's frames, decodes each ServiceEnvelope (decrypting
// /e/ payloads via the PacketDecoder), records observation provenance for every
// reception (append-only), and extracts telemetry/position exactly once per
// (packet_id, from_num) within the dedup window. Nodes are marked heard so
// liveness is computed by the collector, not the UI (SPEC §2.2).

import Domain
import Foundation
import MeshProtos
import Persistence
import Transport

/// What an ingest run did. Returned so callers/tests can assert on outcomes.
public struct IngestSummary: Sendable, Equatable {
    public var framesProcessed = 0
    public var packetsDecoded = 0
    public var decodeErrors = 0
    public var observationsRecorded = 0
    public var duplicateDeliveriesSkipped = 0
    public var telemetryPointsRecorded = 0
    public var positionFixesRecorded = 0
    public var extractionsDeduped = 0
    public init() {}
}

public struct IngestPipeline: Sendable {
    private let store: MeshStore
    private let decoder: PacketDecoder
    private let dedupWindowSeconds: Double

    public init(store: MeshStore, decoder: PacketDecoder, dedupWindowSeconds: Double = 600) {
        self.store = store
        self.decoder = decoder
        self.dedupWindowSeconds = dedupWindowSeconds
    }

    /// Run the pipeline over a transport. `onDecoded` is called for every decoded
    /// packet (every gateway reception, before dedup) so a live consumer — e.g. the
    /// network visualization — can tap the stream while the pipeline persists.
    @discardableResult
    public func run(
        _ transport: any MeshTransport,
        onDecoded: @Sendable (DecodedPacket, InboundFrame) async -> Void = { _, _ in }
    ) async throws -> IngestSummary {
        var summary = IngestSummary()
        var dedup = DedupWindow(windowSeconds: dedupWindowSeconds)

        for await frame in transport.frames() {
            summary.framesProcessed += 1

            let decoded: DecodedPacket?
            do {
                decoded = try decoder.decode(serviceEnvelope: frame.payload, receivedAt: frame.receivedAt)
            } catch {
                summary.decodeErrors += 1
                continue
            }
            guard let packet = decoded else { continue }
            summary.packetsDecoded += 1
            await onDecoded(packet, frame)
            let node = Int64(packet.from)

            try await store.markHeard(nodeNum: node, at: packet.rxTime)

            // Provenance per reception (append-only); exact re-delivery is rejected.
            do {
                _ = try await store.recordObservation(observationRecord(packet, frame: frame))
                summary.observationsRecorded += 1
            } catch let error as StoreError {
                guard case .duplicate = error else { throw error }
                summary.duplicateDeliveriesSkipped += 1
                continue
            }

            // Count telemetry/position once per (packet_id, from) within the window.
            guard dedup.admit(packet.dedupKey, at: packet.rxTime) else {
                summary.extractionsDeduped += 1
                continue
            }
            switch packet.port {
            case .telemetry:
                summary.telemetryPointsRecorded += try await extractTelemetry(packet, node: node)
            case .position:
                if try await extractPosition(packet, node: node) { summary.positionFixesRecorded += 1 }
            default:
                break
            }
        }
        return summary
    }

    // MARK: Mapping

    private func observationRecord(_ packet: DecodedPacket, frame: InboundFrame) -> ObservationRecord {
        ObservationRecord(
            node_num: Int64(packet.from),
            packet_id: Int64(packet.packetID),
            transport: Persistence.Transport(rawValue: frame.transport.rawValue) ?? .mqtt,
            gateway_id: frame.gatewayID,
            rx_time: packet.rxTime.nanosecondsSinceEpoch,
            rx_rssi: packet.rxRssi,
            rx_snr: packet.rxSnr,
            hop_start: packet.hopStart.map(Int.init),
            hop_limit: packet.hopLimit.map(Int.init)
        )
    }

    private func extractTelemetry(_ packet: DecodedPacket, node: Int64) async throws -> Int {
        guard let telemetry = try? Telemetry(serializedBytes: Data(packet.payload)),
              let variant = telemetry.variant else { return 0 }
        let t = packet.rxTime.nanosecondsSinceEpoch
        let rows: [TelemetryRecord] = switch variant {
        case let .deviceMetrics(metrics): Self.deviceRows(metrics, node: node, t: t)
        case let .environmentMetrics(metrics): Self.environmentRows(metrics, node: node, t: t)
        default: []
        }
        for row in rows {
            try await store.appendTelemetry(row)
        }
        return rows.count
    }

    private static func deviceRows(_ metrics: DeviceMetrics, node: Int64, t: Int64) -> [TelemetryRecord] {
        var rows: [TelemetryRecord] = []
        func add(_ key: String, _ value: Double) {
            rows.append(TelemetryRecord(node_num: node, t: t, kind: .device, key: key, value: value))
        }
        if metrics.hasBatteryLevel { add("battery_pct", Double(metrics.batteryLevel)) }
        if metrics.hasVoltage { add("voltage", Double(metrics.voltage)) }
        if metrics.hasChannelUtilization { add("channel_util", Double(metrics.channelUtilization)) }
        if metrics.hasAirUtilTx { add("air_util_tx", Double(metrics.airUtilTx)) }
        if metrics.hasUptimeSeconds { add("uptime", Double(metrics.uptimeSeconds)) }
        return rows
    }

    private static func environmentRows(
        _ metrics: EnvironmentMetrics,
        node: Int64,
        t: Int64
    ) -> [TelemetryRecord] {
        var rows: [TelemetryRecord] = []
        func add(_ key: String, _ value: Double) {
            rows.append(TelemetryRecord(node_num: node, t: t, kind: .environment, key: key, value: value))
        }
        if metrics.hasTemperature { add("temp", Double(metrics.temperature)) }
        if metrics.hasRelativeHumidity { add("humidity", Double(metrics.relativeHumidity)) }
        if metrics.hasBarometricPressure { add("pressure", Double(metrics.barometricPressure)) }
        return rows
    }

    private func extractPosition(_ packet: DecodedPacket, node: Int64) async throws -> Bool {
        // A node reporting no GPS fix (no lat/lon) is never persisted as a position
        // (SPEC §2.3 "no position source").
        guard let position = try? Position(serializedBytes: Data(packet.payload)),
              position.hasLatitudeI, position.hasLongitudeI else { return false }
        try await store.appendPositionFix(PositionFixRecord(
            node_num: node,
            t: packet.rxTime.nanosecondsSinceEpoch,
            lat: Double(position.latitudeI) * 1e-7,
            lon: Double(position.longitudeI) * 1e-7,
            alt: position.hasAltitude ? Double(position.altitude) : nil,
            sats: position.satsInView != 0 ? Int(position.satsInView) : nil,
            h_accuracy: nil,
            precision_bits: position.precisionBits != 0 ? Int(position.precisionBits) : nil
        ))
        return true
    }
}
