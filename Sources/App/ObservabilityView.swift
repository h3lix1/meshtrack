// ObservabilityView — meshtrackd health + ingestion metrics (SPEC §4). Metric
// tiles, a throughput sparkline, and per-broker connection status. Backed by the
// daemon's counters; here driven by sample metrics.

import Charts
import SwiftUI

public struct BrokerStatus: Identifiable, Sendable {
    public let id = UUID()
    public let name: String
    public let connected: Bool
    public let messagesPerSec: Double

    public init(name: String, connected: Bool, messagesPerSec: Double) {
        self.name = name
        self.connected = connected
        self.messagesPerSec = messagesPerSec
    }
}

public struct DaemonMetrics: Sendable {
    public let ingestRate: Double
    public let decodeSuccessPct: Double
    public let decryptSuccessPct: Double
    public let dedupCollapsePct: Double
    public let nodesTracked: Int
    public let telemetryRows: Int
    public let uptimeHours: Double
    public let throughput: [Double]
    public let brokers: [BrokerStatus]

    public init(
        ingestRate: Double, decodeSuccessPct: Double, decryptSuccessPct: Double,
        dedupCollapsePct: Double, nodesTracked: Int, telemetryRows: Int,
        uptimeHours: Double, throughput: [Double], brokers: [BrokerStatus]
    ) {
        self.ingestRate = ingestRate
        self.decodeSuccessPct = decodeSuccessPct
        self.decryptSuccessPct = decryptSuccessPct
        self.dedupCollapsePct = dedupCollapsePct
        self.nodesTracked = nodesTracked
        self.telemetryRows = telemetryRows
        self.uptimeHours = uptimeHours
        self.throughput = throughput
        self.brokers = brokers
    }
}

public struct ObservabilityView: View {
    public let metrics: DaemonMetrics
    public init(metrics: DaemonMetrics) {
        self.metrics = metrics
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Observability").font(.title.bold()).foregroundStyle(.white)
                Text("meshtrackd health and ingestion metrics")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            metricTiles
            throughputCard
            brokerCard
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.03, green: 0.04, blue: 0.10))
    }

    private var metricTiles: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            MetricTile(
                label: "INGEST RATE",
                value: String(format: "%.0f", metrics.ingestRate),
                unit: "msg/s",
                tint: .cyan
            )
            MetricTile(
                label: "DECODE OK",
                value: String(format: "%.1f", metrics.decodeSuccessPct),
                unit: "%",
                tint: .green
            )
            MetricTile(
                label: "DECRYPT OK",
                value: String(format: "%.1f", metrics.decryptSuccessPct),
                unit: "%",
                tint: metrics.decryptSuccessPct > 90 ? .green : .yellow
            )
            MetricTile(
                label: "DUPES COLLAPSED",
                value: String(format: "%.0f", metrics.dedupCollapsePct),
                unit: "%",
                tint: .mint
            )
            MetricTile(label: "NODES", value: "\(metrics.nodesTracked)", unit: "tracked", tint: .white)
            MetricTile(label: "TELEMETRY", value: "\(metrics.telemetryRows)", unit: "rows", tint: .white)
            MetricTile(
                label: "UPTIME",
                value: String(format: "%.1f", metrics.uptimeHours),
                unit: "h",
                tint: .white
            )
            MetricTile(
                label: "BROKERS",
                value: "\(metrics.brokers.count(where: \.connected))/\(metrics.brokers.count)",
                unit: "up",
                tint: .green
            )
        }
    }

    private var throughputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("THROUGHPUT — msgs/sec").font(.system(size: 10, weight: .bold)).tracking(1)
                .foregroundStyle(.secondary)
            Chart(Array(metrics.throughput.enumerated()), id: \.offset) { index, value in
                AreaMark(x: .value("t", index), y: .value("msgs/s", value))
                    .foregroundStyle(.linearGradient(
                        colors: [.cyan.opacity(0.45), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                LineMark(x: .value("t", index), y: .value("msgs/s", value))
                    .foregroundStyle(.cyan).interpolationMethod(.catmullRom)
            }
            .chartXAxis(.hidden)
            .frame(height: 140)
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var brokerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("BROKERS").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.secondary)
            ForEach(metrics.brokers) { broker in
                HStack(spacing: 10) {
                    Circle().fill(broker.connected ? .green : .red).frame(width: 8, height: 8)
                        .shadow(color: broker.connected ? .green : .red, radius: 3)
                    Text(broker.name).font(.system(size: 12, design: .monospaced)).foregroundStyle(.white)
                    Spacer()
                    Text(String(format: "%.0f msg/s", broker.messagesPerSec))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct MetricTile: View {
    let label: String
    let value: String
    let unit: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 9, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 24, weight: .bold, design: .rounded)).foregroundStyle(tint)
                Text(unit).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 11))
    }
}
