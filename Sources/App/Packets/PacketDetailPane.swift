// PacketDetailPane — the detail half of the packet inspector (G6, item 10). Shows
// one packet id's whole story across every reception: a header with the reception
// count + hop range, the shared decoded field grid, the latency journey + distinct
// paths it took, a per-reception table, the byte-level hex dump of the newest
// reception, and a small latency-distribution histogram over the window.
//
// Bespoke layout + monospaced hex dump (no stock controls) for headless snapshot
// fidelity. The per-reception / path / journey sub-views live in
// PacketReceptionViews.swift to keep this file and type small.

import Domain
import SwiftUI

struct PacketDetailPane: View {
    let aggregate: AggregatedPacket
    let distribution: LatencyDistribution

    /// The newest reception — backs the shared field grid + hex dump.
    private var packet: InspectedPacket {
        aggregate.representative
    }

    private var color: Color {
        PacketColor.color(for: aggregate.packetID)
    }

    var body: some View {
        // The detail scrolls vertically (item 5): the per-reception table + hex dump
        // grow as receptions accumulate, but the pane stays anchored at the TOP rather
        // than auto-following the newest reception. `defaultScrollAnchor(.top)` pins the
        // resting position to the top, and `.id(aggregate.packetID)` rebuilds the scroll
        // on (re)selection so a freshly-picked packet's detail starts at the top.
        // `cardStack` is a bespoke, intrinsically-sized subview (no trailing Spacer — it
        // would expand unbounded in a vertical scroll view) anchored top-leading so the
        // headless ImageRenderer renders the full stack. Mirrors CollisionMatrixView.
        ScrollView(.vertical) {
            cardStack
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .defaultScrollAnchor(.top)
        .id(aggregate.packetID)
    }

    /// The detail's bespoke card stack, sized to its intrinsic height in the ScrollView.
    private var cardStack: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            fieldGrid
            PacketLatencyJourneyCard(journey: aggregate.latencyJourney, accent: color)
            PacketPathsCard(paths: aggregate.paths, accent: PacketInspectorTheme.accent)
            PacketReceptionsCard(receptions: aggregate.receptions, accent: PacketInspectorTheme.accent)
            hexDump
            distributionCard
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 5).fill(color)
                .frame(width: 10, height: 34).shadow(color: color, radius: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text("Packet \(InspectedPacket.hexID(aggregate.packetID))")
                    .font(.system(size: 18, weight: .bold))
                Text("\(aggregate.fromHex) → \(aggregate.toHex) · \(aggregate.portName)")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            headerBadges
        }
    }

    @ViewBuilder
    private var headerBadges: some View {
        if aggregate.wasEncrypted {
            badge("ENCRYPTED", tint: .yellow, fill: .yellow.opacity(0.18))
        }
        badge("×\(aggregate.receptionCount)", tint: color, fill: color.opacity(0.2))
        if let hopRange = aggregate.hopRangeText {
            badge("\(hopRange) HOPS", tint: color, fill: color.opacity(0.2))
        }
    }

    private func badge(_ text: String, tint: Color, fill: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .heavy))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(fill, in: Capsule()).foregroundStyle(tint)
    }

    /// An eager `Grid` (not `LazyVGrid`): lazy containers need a real scroll viewport
    /// and crash the headless ImageRenderer when nested in a ScrollView. Two eager rows
    /// of three give the same 3-column field layout, render-safe.
    private var fieldGrid: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                field("CHANNEL", "\(aggregate.channel)")
                field("RECEPTIONS", "\(aggregate.receptionCount)")
                field("DISTINCT GATEWAYS", "\(aggregate.distinctGatewayCount)")
            }
            GridRow {
                field("DISTINCT PATHS", "\(aggregate.distinctPathCount)")
                field("HOP RANGE", aggregate.hopRangeText ?? "—")
                field("PORT #", "\(aggregate.port.portNumRawValue)")
            }
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 9, weight: .semibold)).tracking(0.5)
                .foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
    }

    // MARK: Byte-level hex dump (newest reception's payload)

    private var hexDump: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PAYLOAD BYTES — latest reception")
                .font(.system(size: 10, weight: .bold)).tracking(0.5).foregroundStyle(.secondary)
            if packet.isPayloadEmpty {
                Text("(empty payload)").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(packet.hexDump()) { row in
                        HStack(spacing: 14) {
                            Text(row.offsetText).foregroundStyle(.secondary)
                            Text(row.hexText).foregroundStyle(.white.opacity(0.9))
                            Text(row.asciiText).foregroundStyle(PacketInspectorTheme.accent.opacity(0.9))
                        }
                        .font(.system(size: 11, design: .monospaced))
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Latency distribution over the window

    private var distributionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("LATENCY DISTRIBUTION — window")
                .font(.system(size: 10, weight: .bold)).tracking(0.5).foregroundStyle(.secondary)
            if distribution.isEmpty {
                Text("No plausible latency samples yet.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 18) {
                    stat("MIN", "\(distribution.minMillis)ms")
                    stat("MEDIAN", "\(distribution.medianMillis)ms")
                    stat("MEAN", "\(distribution.meanMillis)ms")
                    stat("P95", "\(distribution.p95Millis)ms")
                    stat("MAX", "\(distribution.maxMillis)ms")
                }
                LatencyHistogram(distribution: distribution, color: PacketInspectorTheme.accent)
                    .frame(height: 70)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A solid translucent fill, not `.ultraThinMaterial`: materials nested in a
        // ScrollView crash the headless ImageRenderer (and render poorly headless).
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .bold, design: .rounded))
        }
    }
}
