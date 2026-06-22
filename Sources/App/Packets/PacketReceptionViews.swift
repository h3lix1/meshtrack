// PacketReceptionViews — the per-aggregate detail cards (G6, item 10): the latency
// journey across receptions, the distinct paths a packet took, and a per-reception
// table. Bespoke rows (no stock List/Table/Grid) so they render under the headless
// ImageRenderer snapshot gate. Split out of PacketDetailPane to keep files small.

import Domain
import SwiftUI

/// The latency journey across receptions: min/median/spread + first/last heard.
/// Implausible (skewed-RTC) receptions are excluded and noted.
struct PacketLatencyJourneyCard: View {
    let journey: PacketLatencyJourney
    var accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LATENCY JOURNEY — across receptions")
                .font(.system(size: 10, weight: .bold)).tracking(0.5).foregroundStyle(.secondary)
            if journey.isEmpty {
                Text(journey.excludedCount > 0
                    ? "No plausible latency (\(journey.excludedCount) reception(s) clock-skewed)."
                    : "No latency samples.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 18) {
                    stat("MIN", journey.minMillis)
                    stat("MEDIAN", journey.medianMillis)
                    stat("MAX", journey.maxMillis)
                    stat("SPREAD", journey.spreadMillis)
                }
                if journey.excludedCount > 0 {
                    Text("\(journey.excludedCount) reception(s) excluded — clock skew")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func stat(_ label: String, _ value: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            Text(value.map { "\($0)ms" } ?? "—")
                .font(.system(size: 13, weight: .bold, design: .rounded)).foregroundStyle(accent)
        }
    }
}

/// The distinct relay/gateway combinations the packet arrived through.
struct PacketPathsCard: View {
    let paths: [PacketPath]
    var accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DISTINCT PATHS — relay → gateway")
                .font(.system(size: 10, weight: .bold)).tracking(0.5).foregroundStyle(.secondary)
            ForEach(paths) { path in
                HStack(spacing: 10) {
                    Text(path.relayText)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
                    Text("→").foregroundStyle(.secondary)
                    Text(path.gatewayText)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(accent)
                    Spacer()
                    Text("×\(path.count)")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A per-reception table: gateway, relay byte, hops, SNR/RSSI, channel, latency.
struct PacketReceptionsCard: View {
    let receptions: [InspectedPacket]
    var accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("RECEPTIONS — \(receptions.count)")
                .font(.system(size: 10, weight: .bold)).tracking(0.5).foregroundStyle(.secondary)
            headerRow
            ForEach(receptions) { reception in
                ReceptionRow(reception: reception, accent: accent)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            cell("GATEWAY", weight: 3)
            cell("RELAY", weight: 2)
            cell("HOP", weight: 1)
            cell("SNR", weight: 1)
            cell("RSSI", weight: 1)
            cell("CH", weight: 1)
            cell("LAT", weight: 2)
        }
        .font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func cell(_ text: String, weight: CGFloat) -> some View {
        Text(text).frame(maxWidth: .infinity, alignment: .leading).layoutPriority(weight)
    }
}

/// One row of the per-reception table.
private struct ReceptionRow: View {
    let reception: InspectedPacket
    var accent: Color

    var body: some View {
        HStack(spacing: 0) {
            value(reception.gatewayText, weight: 3)
            value(reception.relayByteText, weight: 2)
            value(reception.hops.map { "\($0)" } ?? "—", weight: 1)
            value(snrText, weight: 1)
            value(rssiText, weight: 1)
            value("\(reception.channel)", weight: 1)
            latencyValue
        }
        .font(.system(size: 10, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
    }

    private var latencyValue: some View {
        Group {
            if let millis = reception.plausibleLatencyMillis {
                Text("\(millis)ms").foregroundStyle(accent)
            } else if reception.latencyMillis != nil {
                Text("skew").foregroundStyle(.orange)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(2)
    }

    private var snrText: String {
        reception.packet.rxSnr.map { String(format: "%.1f", $0) } ?? "—"
    }

    private var rssiText: String {
        reception.packet.rxRssi.map { "\($0)" } ?? "—"
    }

    private func value(_ text: String, weight: CGFloat) -> some View {
        Text(text).frame(maxWidth: .infinity, alignment: .leading).layoutPriority(weight)
    }
}
