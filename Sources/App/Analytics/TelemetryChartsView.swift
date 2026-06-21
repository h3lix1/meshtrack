// TelemetryChartsView — real Swift Charts time-series for one node's telemetry
// (Phase 7 G4). Store-backed via `TelemetryChartsViewModel`; replaces the
// sample-fed `TelemetryChartView`. Each metric gets its own line chart (with the
// rollup min/max band when downsampled), grouped into device + environment
// sections, with a range picker (6H / 24H / 7D / 30D) that re-reads at the right
// storage resolution.
//
// Swift Charts is a system framework (no Package.swift change). The line charts
// are for the live app; snapshots use the bespoke-Canvas analytics views.

import Charts
import Domain
import SwiftUI

public struct TelemetryChartsView: View {
    @State private var viewModel: TelemetryChartsViewModel

    public init(viewModel: TelemetryChartsViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if viewModel.hasData {
                    section("Device", series: viewModel.deviceSeries)
                    section("Environment", series: viewModel.environmentSeries)
                } else {
                    emptyState
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(AnalyticsTheme.background)
        .task { try? await viewModel.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Telemetry").font(.title2.bold()).foregroundStyle(.white)
            Text(caption).font(.system(size: 12)).foregroundStyle(.secondary)
            rangePicker
        }
    }

    private var caption: String {
        switch viewModel.resolution {
        case .raw: "Raw samples from the retained telemetry."
        case .hourly: "Hourly averages (min–max band) from the rollup."
        case .daily: "Daily averages (min–max band) from the rollup."
        }
    }

    private var rangePicker: some View {
        HStack(spacing: 8) {
            ForEach(TelemetryRange.allCases) { range in
                Button {
                    Task { try? await viewModel.select(range) }
                } label: {
                    Text(range.label)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(range == viewModel.range
                                    ? AnalyticsTheme.accent.opacity(0.85)
                                    : Color.white.opacity(0.08))
                        )
                        .foregroundStyle(range == viewModel.range ? .black : .white.opacity(0.85))
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, series: [TelemetrySeries.Built]) -> some View {
        if !series.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AnalyticsTheme.accent)
                ForEach(series) { built in
                    metricChart(built)
                }
            }
        }
    }

    private func metricChart(_ built: TelemetrySeries.Built) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(built.metric.label).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                if let latest = built.points.last {
                    Text(format(latest.value, unit: built.metric.unit))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(AnalyticsTheme.accent)
                }
            }
            chart(built)
                .frame(height: 150)
        }
        .padding(16)
        .background(AnalyticsTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func chart(_ built: TelemetrySeries.Built) -> some View {
        Chart {
            ForEach(built.points) { point in
                if let lower = point.minValue, let upper = point.maxValue {
                    AreaMark(
                        x: .value("Time", point.secondsSinceEpoch),
                        yStart: .value("Min", lower),
                        yEnd: .value("Max", upper)
                    )
                    .foregroundStyle(AnalyticsTheme.accent.opacity(0.16))
                }
            }
            ForEach(built.points) { point in
                LineMark(
                    x: .value("Time", point.secondsSinceEpoch),
                    y: .value(built.metric.label, point.value)
                )
                .foregroundStyle(AnalyticsTheme.accent)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2.2))
            }
        }
        .chartYScale(domain: yDomain(built))
        .chartYAxis { AxisMarks(position: .leading) }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) }
    }

    private func yDomain(_ built: TelemetrySeries.Built) -> ClosedRange<Double> {
        if let domain = built.metric.domain { return domain }
        let values = built.points.flatMap { [$0.value, $0.minValue, $0.maxValue].compactMap(\.self) }
        guard let low = values.min(), let high = values.max() else { return 0 ... 1 }
        if high - low < 1e-6 { return (low - 1) ... (high + 1) }
        let pad = (high - low) * 0.1
        return (low - pad) ... (high + pad)
    }

    private func format(_ value: Double, unit: String) -> String {
        let rounded = (value * 10).rounded() / 10
        let text = rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
        return unit == "%" || unit == "°C" ? "\(text)\(unit)" : "\(text) \(unit)"
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No telemetry in range")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
            Text("Widen the range or wait for the node to report.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }
}

/// Shared dark palette for the analytics section, matching the existing GUI.
enum AnalyticsTheme {
    static let background = Color(red: 0.03, green: 0.04, blue: 0.10)
    static let card = Color(red: 0.07, green: 0.09, blue: 0.18)
    static let accent = Color(red: 0.45, green: 0.85, blue: 1.0)
}

#Preview("Telemetry charts") {
    TelemetryChartsPreview()
        .frame(width: 720, height: 760)
}

/// Wrapper that seeds an in-memory store async, then hands the VM to the view.
private struct TelemetryChartsPreview: View {
    @State private var viewModel: TelemetryChartsViewModel?
    private let now: Int64 = 1000 * 3_600_000_000_000

    var body: some View {
        Group {
            if let viewModel {
                TelemetryChartsView(viewModel: viewModel)
            } else {
                Color.clear
            }
        }
        .task {
            guard let store = try? await AnalyticsPreviewData.seededStore(nowNanos: now) else { return }
            viewModel = TelemetryChartsViewModel(
                store: store,
                nodeNum: AnalyticsPreviewData.nodeNum,
                now: { Instant(nanosecondsSinceEpoch: now) }
            )
        }
    }
}
