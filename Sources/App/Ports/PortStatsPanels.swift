// PortStatsPanels — the two extras (item 13) that ride the Port-numbers screen's
// right rail: busiest channels, and the mesh-wide hop-count distribution. Bespoke
// dark-theme bars (no stock Chart/ScrollView) so they snapshot deterministically.

import SwiftUI

/// Busiest channels: each channel hash with a reception bar + share, ordered by load.
struct ChannelTrafficPanel: View {
    let channels: [ChannelTrafficRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BUSIEST CHANNELS")
                .font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.secondary)
            if channels.isEmpty {
                Text("No channel traffic yet.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ForEach(channels) { row in
                    channelRow(row, peak: channels.first?.receptions ?? 1)
                }
            }
        }
    }

    private func channelRow(_ row: ChannelTrafficRow, peak: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(String(format: "0x%02X", row.channel))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                Spacer()
                Text("\(row.receptions)").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.06))
                    Capsule().fill(PortPalette.accent.opacity(0.5))
                        .frame(width: max(3, geo.size.width * Double(row.receptions) / Double(max(peak, 1))))
                }
            }
            .frame(height: 5)
        }
    }
}

/// Mesh-wide hop-count distribution: how far packets are travelling across the mesh.
struct HopDistributionPanel: View {
    let hops: [HopBucketRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HOP DISTRIBUTION")
                .font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.secondary)
            if hops.isEmpty {
                Text("No hop data yet.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                ForEach(hops) { bucket in
                    hopRow(bucket, peak: hops.map(\.receptions).max() ?? 1)
                }
            }
        }
    }

    private func hopRow(_ bucket: HopBucketRow, peak: Int) -> some View {
        HStack(spacing: 8) {
            Text("\(bucket.hops)h").font(.system(size: 11, weight: .semibold))
                .frame(width: 28, alignment: .leading).foregroundStyle(.white.opacity(0.85))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.06))
                    Capsule().fill(Color(red: 0.55, green: 0.85, blue: 0.5).opacity(0.55))
                        .frame(width: max(
                            3,
                            geo.size.width * Double(bucket.receptions) / Double(max(peak, 1))
                        ))
                }
            }
            .frame(height: 7)
            Text("\(bucket.receptions)").font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}
