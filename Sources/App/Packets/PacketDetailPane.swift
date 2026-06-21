// PacketDetailPane — the detail half of the packet inspector (G6): header, decoded
// field grid, the byte-level hex dump, the receive→publish latency for this packet,
// and a small latency-distribution histogram over the window. Bespoke layout +
// monospaced hex dump (no stock controls) for headless snapshot fidelity.

import Domain
import SwiftUI

struct PacketDetailPane: View {
    let packet: InspectedPacket
    let distribution: LatencyDistribution

    private var color: Color {
        PacketColor.color(for: packet.packetID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            fieldGrid
            latencyRow
            hexDump
            distributionCard
            Spacer(minLength: 0)
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 5).fill(color)
                .frame(width: 10, height: 34).shadow(color: color, radius: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text("Packet \(InspectedPacket.hexID(packet.packetID))")
                    .font(.system(size: 18, weight: .bold))
                Text("\(packet.fromHex) → \(packet.toHex) · \(packet.portName)")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            if packet.wasEncrypted {
                Text("ENCRYPTED")
                    .font(.system(size: 10, weight: .heavy))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.yellow.opacity(0.18), in: Capsule())
                    .foregroundStyle(.yellow)
            }
            if let hops = packet.hops {
                Text("\(hops) HOPS")
                    .font(.system(size: 12, weight: .heavy))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(color.opacity(0.2), in: Capsule()).foregroundStyle(color)
            }
        }
    }

    private var fieldGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            field("CHANNEL", "\(packet.channel)")
            field("HOP START / LIMIT", hopText)
            field("RELAY BYTE", packet.relayByteText)
            field("GATEWAY", packet.gatewayText)
            field("PAYLOAD", "\(packet.payloadByteCount) B")
            field("PORT #", "\(packet.port.portNumRawValue)")
        }
    }

    private var hopText: String {
        guard let start = packet.packet.hopStart, let limit = packet.packet.hopLimit else { return "—" }
        return "\(start) / \(limit)"
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

    // MARK: Latency for this packet

    @ViewBuilder
    private var latencyRow: some View {
        if let millis = packet.latencyMillis {
            HStack(spacing: 10) {
                Text("RECEIVE→PUBLISH")
                    .font(.system(size: 10, weight: .bold)).tracking(0.5)
                    .foregroundStyle(.secondary)
                Text(millis < 0 ? "\(millis)ms (clock skew)" : "\(millis)ms")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(millis < 0 ? .orange : PacketInspectorTheme.accent)
                Spacer()
            }
            .padding(12)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        } else {
            HStack {
                Text("RECEIVE→PUBLISH")
                    .font(.system(size: 10, weight: .bold)).tracking(0.5)
                    .foregroundStyle(.secondary)
                Text("unavailable (no ingest time)")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: Byte-level hex dump

    private var hexDump: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PAYLOAD BYTES")
                .font(.system(size: 10, weight: .bold)).tracking(0.5).foregroundStyle(.secondary)
            if packet.isPayloadEmpty {
                Text("(empty payload)").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(packet.hexDump()) { row in
                        HStack(spacing: 14) {
                            Text(row.offsetText)
                                .foregroundStyle(.secondary)
                            Text(row.hexText)
                                .foregroundStyle(.white.opacity(0.9))
                            Text(row.asciiText)
                                .foregroundStyle(PacketInspectorTheme.accent.opacity(0.9))
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
                Text("No latency samples yet.").font(.system(size: 12)).foregroundStyle(.secondary)
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
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .bold, design: .rounded))
        }
    }
}
