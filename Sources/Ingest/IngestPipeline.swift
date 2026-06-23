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
    public var messagesRecorded = 0
    public var nodeInfoRecorded = 0
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

    /// Run the pipeline over `transport`'s frames.
    ///
    /// - Parameter onDecoded: an optional tap invoked once per successfully
    ///   decoded packet, BEFORE persistence side-effects, so the live trace feed
    ///   (G2) can animate every reception even when its extraction is deduped or
    ///   the packet is a non-extracted port. It is awaited; keep it cheap.
    @discardableResult
    public func run(
        _ transport: any MeshTransport,
        onDecoded: (@Sendable (DecodedPacket) async -> Void)? = nil
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
            await onDecoded?(packet)
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

            // Count telemetry/position/message once per (packet_id, from) in window.
            // Two dedup layers share the same window: the in-memory `DedupWindow`
            // (fast, per-run — surfaced in `extractionsDeduped`) and a DURABLE
            // ledger in the store (Finding 5). The ledger is what makes a reconnect
            // re-delivery — a NEW run() with a FRESH in-memory window, re-admitted
            // here — still extract exactly once. It silently replaces the role the
            // v5 permanent unique index played (a within-run dup is the counted
            // case; a cross-run dup is absorbed durably) and, unlike that index,
            // lets a legitimate packet-id reuse AFTER the window record a new
            // extraction rather than dropping it forever.
            guard dedup.admit(packet.dedupKey, at: packet.rxTime) else {
                summary.extractionsDeduped += 1
                continue
            }
            guard try await store.admitExtraction(
                packetID: Int64(packet.packetID),
                fromNum: Int64(packet.from),
                at: packet.rxTime,
                windowSeconds: dedupWindowSeconds
            ) else {
                // Durable cross-run dedup: absorbed silently, just like the v5 index
                // it replaces, so within-run `extractionsDeduped` stays meaningful.
                continue
            }
            try await extract(packet, node: node, frame: frame, into: &summary)
        }
        return summary
    }

    /// Persist the deduped app-payload extraction for `packet` (telemetry,
    /// position, or text message), tallying into `summary`. Non-extracted ports
    /// are no-ops.
    private func extract(
        _ packet: DecodedPacket,
        node: Int64,
        frame: InboundFrame,
        into summary: inout IngestSummary
    ) async throws {
        switch packet.port {
        case .telemetry:
            summary.telemetryPointsRecorded += try await extractTelemetry(packet, node: node)
        case .position:
            if try await extractPosition(packet, node: node) { summary.positionFixesRecorded += 1 }
        case .textMessage:
            if try await extractMessage(packet, channelName: Self.channelName(from: frame.topic)) {
                summary.messagesRecorded += 1
            }
        case .nodeInfo:
            if try await extractNodeInfo(packet, node: node) { summary.nodeInfoRecorded += 1 }
        default:
            break
        }
    }

    // MARK: Mapping

    private func observationRecord(_ packet: DecodedPacket, frame: InboundFrame) -> ObservationRecord {
        ObservationRecord(
            node_num: Int64(packet.from),
            packet_id: Int64(packet.packetID),
            transport: Persistence.Transport(rawValue: frame.transport.rawValue) ?? .mqtt,
            gateway_id: frame.gatewayID,
            // The observation's rx_time keeps the node's CLAIMED (firmware) time so the
            // descriptive receive→publish latency (`ingest_time − rx_time`, SPEC §2.11)
            // stays real. Everything that orders/places packets reads our own clock
            // instead (the timeline reads ingest_time; live traces read packet.rxTime).
            // Falls back to our frame-receipt clock when the firmware omitted its time.
            rx_time: (packet.nodeRxTime ?? packet.rxTime).nanosecondsSinceEpoch,
            rx_rssi: packet.rxRssi,
            rx_snr: packet.rxSnr,
            hop_start: packet.hopStart.map(Int.init),
            hop_limit: packet.hopLimit.map(Int.init),
            // Our Clock wall-clock at frame receipt — the latency source (SPEC §2.11).
            ingest_time: frame.receivedAt.nanosecondsSinceEpoch
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

    /// Decode a `NODEINFO_APP` payload (a `User` protobuf) and fill in the node's
    /// identity: `short_name`, `long_name`, `hexid`, and `hw_model`/`role` when the
    /// node advertises them. Fetch-merge-upsert so we never clobber ownership flags
    /// (`is_mine`/`is_managed`), `node_class`, or the `first_seen_at`/`last_heard_at`
    /// liveness `markHeard` already maintains. Empty names and an `.unset` hw model
    /// are left untouched (a sparse NODEINFO must not erase a previously-known name);
    /// `role` is always reflected since NODEINFO always advertises one (CLIENT is the
    /// firmware default). Malformed bytes are skipped, never fatal — matching the
    /// telemetry/position handling. Returns whether a node row was updated.
    private func extractNodeInfo(_ packet: DecodedPacket, node: Int64) async throws -> Bool {
        guard let user = try? User(serializedBytes: Data(packet.payload)) else { return false }
        // `markHeard` ran first, so the row exists; fall back to a fresh record if not.
        let t = packet.rxTime.nanosecondsSinceEpoch
        // Fetch-merge-upsert in a SINGLE transaction so a concurrent ownership /
        // admin write landing between the read and the save is not clobbered by a
        // stale full-row snapshot (Finding 9). The merge touches only the identity
        // columns NODEINFO advertises — ownership flags, class, and liveness are
        // left to whatever the freshly-read row holds.
        let shortName = user.shortName
        let longName = user.longName
        let id = user.id
        let hwModelName = user.hwModel != .unset ? Self.hardwareModelName(user.hwModel) : nil
        // Role always carries a value in NODEINFO (CLIENT is the firmware default).
        let roleName = Self.roleName(user.role)
        try await store.updateNode(
            nodeNum: node,
            orInsert: { NodeRecord(node_num: node, first_seen_at: t, last_heard_at: t) },
            merge: { record in
                if !shortName.isEmpty { record.short_name = shortName }
                if !longName.isEmpty { record.long_name = longName }
                if !id.isEmpty { record.hexid = id }
                if let hwModelName { record.hw_model = hwModelName }
                record.role = roleName
            }
        )
        return true
    }

    /// Firmware (proto) names for `Config.DeviceConfig.Role`, keyed by raw value.
    /// An explicit table (rather than reflection) keeps the SCREAMING_SNAKE_CASE the
    /// App's role inference parses stable across SwiftProtobuf versions and correct
    /// for the default `.client`, which proto3 JSON would otherwise omit.
    private static let roleNames: [Int: String] = [
        0: "CLIENT", 1: "CLIENT_MUTE", 2: "ROUTER", 3: "ROUTER_CLIENT", 4: "REPEATER",
        5: "TRACKER", 6: "SENSOR", 7: "TAK", 8: "CLIENT_HIDDEN", 9: "LOST_AND_FOUND",
        10: "TAK_TRACKER", 11: "ROUTER_LATE", 12: "CLIENT_BASE"
    ]

    /// The firmware (proto) name of a device role — e.g. `ROUTER`, `CLIENT_MUTE`.
    private static func roleName(_ role: Config.DeviceConfig.Role) -> String {
        roleNames[role.rawValue] ?? "UNRECOGNIZED_\(role.rawValue)"
    }

    /// The firmware (proto) name of a hardware model — e.g. `HELTEC_V3`,
    /// `SEEED_XIAO_S3` — which the App's chip-family inference parses. The model set
    /// is large and evolving, so we read the proto name from the message's JSON
    /// (where SwiftProtobuf renders enums by proto name), falling back to the Swift
    /// case name. `.unset` is filtered by the caller, so a present value is always
    /// non-default and therefore appears in JSON. Never throws.
    private static func hardwareModelName(_ model: HardwareModel) -> String {
        let fallback = String(describing: model)
        var user = User()
        user.hwModel = model
        guard let data = try? user.jsonUTF8Data(),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["hwModel"] as? String, !name.isEmpty
        else {
            return fallback
        }
        return name
    }

    /// Decode a `TEXT_MESSAGE_APP` payload (UTF-8 text) into a `message` row
    /// (monitor-only, ADR 0006). An empty body is skipped. Counted once per dedup
    /// key, like telemetry/position. Returns whether a row was recorded.
    private func extractMessage(_ packet: DecodedPacket, channelName: String?) async throws -> Bool {
        guard let body = String(bytes: packet.payload, encoding: .utf8), !body.isEmpty else { return false }
        let message = MeshMessage(
            packetID: packet.packetID,
            from: packet.from,
            to: packet.to,
            channel: packet.channel,
            channelName: channelName,
            body: body,
            rxTime: packet.rxTime
        )
        try await store.recordMessage(MessageRecord(
            packet_id: Int64(message.packetID),
            from_num: Int64(message.from),
            to_num: Int64(message.to),
            channel: Int64(message.channel),
            channel_name: message.channelName,
            body: message.body,
            rx_time: message.rxTime.nanosecondsSinceEpoch,
            is_dm: message.isDirectMessage
        ))
        return true
    }

    /// The human channel name from an MQTT topic `msh/REGION/2/e/CHANNEL/USER`
    /// (the channel is the second-to-last segment). `nil` for serial/BLE or an
    /// unrecognised topic shape.
    static func channelName(from topic: String?) -> String? {
        guard let topic else { return nil }
        let segments = topic.split(separator: "/", omittingEmptySubsequences: true)
        // …/<marker>/<channel>/<user> — channel is second-to-last, marker is
        // fourth-to-last. The `/e/` (encrypted) and `/c/` markers precede the
        // channel; only treat the segment as a channel name when it follows one.
        guard segments.count >= 3 else { return nil }
        let marker = segments[segments.count - 3]
        guard marker == "e" || marker == "c" else { return nil }
        return String(segments[segments.count - 2])
    }
}
