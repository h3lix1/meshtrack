// TelemetryChartView — Swift Charts battery history over the retained telemetry.
// Here driven by sample series for snapshots.

import Charts
import SwiftUI

public struct TelemetrySample: Identifiable, Sendable {
    public let id = UUID()
    public let node: String
    public let hour: Int
    public let battery: Double

    public init(node: String, hour: Int, battery: Double) {
        self.node = node
        self.hour = hour
        self.battery = battery
    }
}

public struct TelemetryChartView: View {
    public let series: [TelemetrySample]
    public init(series: [TelemetrySample]) {
        self.series = series
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Battery — last 24 hours").font(.title2.bold()).foregroundStyle(.white)
            Text("Per-node battery percentage from the retained telemetry rollups.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Chart(series) { sample in
                LineMark(
                    x: .value("Hour", sample.hour),
                    y: .value("Battery %", sample.battery)
                )
                .foregroundStyle(by: .value("Node", sample.node))
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2.5))
            }
            .chartYScale(domain: 0 ... 100)
            .chartLegend(position: .top, alignment: .leading)
            .chartXAxis { AxisMarks(values: .stride(by: 4)) }
            .frame(minHeight: 380)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.03, green: 0.04, blue: 0.10))
    }
}
