// AnalyticsPreviewData — deterministic sample inputs for the analytics previews
// and (optionally) the snapshot harness. New file (does not touch the frozen
// `SampleNetwork.swift`): it builds an in-memory store plus a seeded telemetry +
// node-analytics view model so the bespoke-Canvas analytics views render with
// representative data offline.

import Domain
import Persistence

/// Synthetic, deterministic analytics inputs for previews/snapshots.
public enum AnalyticsPreviewData {
    public static let nodeNum: Int64 = 0xA1B2_C3D4
    public static let nodeName = "Oakland"

    private static let hourNanos: Int64 = 3_600_000_000_000

    /// A spread of observations: three gateways, varied SNR/RSSI, a hop mix, and
    /// receptions clustered across the day (so the heatmap has texture).
    public static func observations() -> [ObservationRecord] {
        var rows: [ObservationRecord] = []
        let gateways = ["! feed-sf", "!relay-oak", "!gw-berk"]
        var packetID: Int64 = 1
        for index in 0 ..< 120 {
            let gateway = gateways[index % gateways.count]
            let snr = -4.0 - Double(index % 14)
            let rssi = -78 - (index % 30)
            let hopStart = 3
            let hopLimit = 3 - (index % 4) // hops 0…3
            // Cluster activity into morning + evening windows.
            let hour = (index % 2 == 0 ? 8 + (index % 4) : 19 + (index % 3))
            let rxNanos = Int64(hour) * hourNanos
            rows.append(ObservationRecord(
                node_num: nodeNum,
                packet_id: packetID,
                transport: .mqtt,
                gateway_id: gateway,
                rx_time: rxNanos,
                rx_rssi: rssi,
                rx_snr: snr,
                hop_start: hopStart,
                hop_limit: max(0, hopLimit)
            ))
            packetID += 1
        }
        return rows
    }

    /// A representative packet-type mix.
    public static func packets() -> [DecodedPacket] {
        func make(_ port: MeshPort, _ count: Int) -> [DecodedPacket] {
            (0 ..< count).map { _ in
                DecodedPacket(
                    from: UInt32(truncatingIfNeeded: nodeNum), to: 0xFFFF_FFFF, packetID: 0, channel: 0,
                    port: port, payload: [], rxTime: Instant(nanosecondsSinceEpoch: 0)
                )
            }
        }
        return make(.telemetry, 42) + make(.position, 28) + make(.nodeInfo, 14)
            + make(.textMessage, 9) + make(.routing, 6) + make(.mapReport, 3)
    }

    /// An in-memory store seeded with 24h of device + environment telemetry.
    public static func seededStore(nowNanos: Int64) async throws -> MeshStore {
        let store = try MeshStore(DatabaseConnection.inMemory())
        for hour in 0 ..< 24 {
            let t = nowNanos - Int64(hour) * hourNanos
            try await append(store, t: t, .device, "battery_pct", 60 + Double(hour) * 1.4)
            try await append(store, t: t, .device, "voltage", 3.6 + Double(hour % 5) * 0.05)
            try await append(store, t: t, .device, "channel_util", 12 + Double(hour % 8))
            try await append(store, t: t, .environment, "temp", 18 + Double(hour % 10))
            try await append(store, t: t, .environment, "humidity", 50 + Double(hour % 20))
        }
        return store
    }

    private static func append(
        _ store: MeshStore,
        t: Int64,
        _ kind: TelemetryKind,
        _ key: String,
        _ value: Double
    ) async throws {
        try await store.appendTelemetry(TelemetryRecord(
            node_num: nodeNum,
            t: t,
            kind: kind,
            key: key,
            value: value
        ))
    }

    /// A node-analytics view model pre-fed with the sample observations + packets.
    @MainActor
    public static func nodeAnalyticsViewModel() throws -> NodeAnalyticsViewModel {
        let store = try MeshStore(DatabaseConnection.inMemory())
        let viewModel = NodeAnalyticsViewModel(store: store, nodeNum: nodeNum)
        viewModel.setObservations(observations())
        viewModel.setPackets(packets())
        return viewModel
    }
}
