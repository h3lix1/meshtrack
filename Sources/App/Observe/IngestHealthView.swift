// IngestHealthView — the live observability dashboard (G10), superseding the
// sample-fed `ObservabilityView`. Renders metric tiles, a bespoke-Canvas
// throughput sparkline, and per-transport health over an `ObservabilityViewModel`.
// Bespoke views (no stock ScrollView/controls) so it renders deterministically
// under the headless `ImageRenderer` snapshot gate (cf. memory: stock controls
// render badly headless).

import SwiftUI

/// The G10 observability dashboard. Bind it to the live `ObservabilityViewModel`
/// the coordinator pushes snapshots into; for snapshots/previews, seed the VM
/// with a fixed `IngestHealth`.
public struct IngestHealthView: View {
    @State private var viewModel: ObservabilityViewModel

    public init(viewModel: ObservabilityViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            metricTiles
            throughputCard
            transportCard
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ObserveTheme.background)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Observability").font(.title.bold()).foregroundStyle(.white)
            Text("live ingestion health — lag, throughput, decode + dedup, per-transport")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var metricTiles: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            ForEach(viewModel.metrics) { metric in
                HealthMetricTile(metric: metric)
            }
        }
    }

    private var throughputCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("THROUGHPUT — msgs/sec")
                .font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.secondary)
            ThroughputSparkline(samples: viewModel.throughput)
                .frame(height: 120)
        }
        .padding(16)
        .background(ObserveTheme.card, in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var transportCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TRANSPORTS")
                .font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.secondary)
            if viewModel.transports.isEmpty {
                Text("No transports connected")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.transports) { transport in
                    TransportRow(health: transport)
                }
            }
        }
        .padding(16)
        .background(ObserveTheme.card, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A single metric tile, tinted by the metric's qualitative status.
private struct HealthMetricTile: View {
    let metric: HealthMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(metric.label)
                .font(.system(size: 9, weight: .semibold)).tracking(0.5).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(metric.value)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(ObserveTheme.tint(for: metric.status))
                Text(metric.unit).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 11))
    }
}

/// A per-transport status row: a connection dot, the label, frame count.
private struct TransportRow: View {
    let health: TransportHealth

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(health.connected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
                .shadow(color: health.connected ? .green : .red, radius: 3)
            Text(health.transport.label)
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.white)
            Spacer()
            Text("\(health.framesReceived) frames")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}

/// A bespoke-Canvas area sparkline — no Swift Charts, so it renders deterministically
/// headless. Draws a filled area + a stroked line; an empty input renders an
/// explicit "No throughput yet" baseline.
struct ThroughputSparkline: View {
    let samples: [Double]

    var body: some View {
        Canvas { context, size in
            guard samples.count >= 2 else {
                let text = context.resolve(
                    Text("No throughput yet").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                )
                context.draw(text, at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            let maxValue = max(samples.max() ?? 1, 0.0001)
            let stepX = size.width / CGFloat(samples.count - 1)
            func point(_ index: Int) -> CGPoint {
                let value = samples[index]
                let y = size.height - CGFloat(value / maxValue) * size.height
                return CGPoint(x: CGFloat(index) * stepX, y: y)
            }

            var line = Path()
            line.move(to: point(0))
            for index in 1..<samples.count { line.addLine(to: point(index)) }

            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()

            context.fill(
                area,
                with: .linearGradient(
                    Gradient(colors: [ObserveTheme.accent.opacity(0.45), .clear]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
            context.stroke(line, with: .color(ObserveTheme.accent), lineWidth: 2)
        }
    }
}

/// Dashboard palette + status→tint mapping (kept here so the derivations stay
/// UI-free).
enum ObserveTheme {
    static let background = Color(red: 0.03, green: 0.04, blue: 0.10)
    static let card = Color.white.opacity(0.05)
    static let accent = Color.cyan

    static func tint(for status: HealthMetric.Status) -> Color {
        switch status {
        case .good: .green
        case .warn: .yellow
        case .bad: .red
        case .neutral: .white
        }
    }
}

#if DEBUG
    #Preview("Observability — healthy feed") {
        IngestHealthView(viewModel: ObservabilityPreviewData.healthy())
            .frame(width: 760, height: 620)
    }

    #Preview("Observability — degraded feed") {
        IngestHealthView(viewModel: ObservabilityPreviewData.degraded())
            .frame(width: 760, height: 620)
    }
#endif
