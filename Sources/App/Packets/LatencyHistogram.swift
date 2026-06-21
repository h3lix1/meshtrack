// LatencyHistogram — a bespoke Canvas bar chart of a LatencyDistribution (G6). A
// hand-drawn histogram (no stock Chart) so it renders deterministically under the
// headless ImageRenderer snapshot gate.

import SwiftUI

struct LatencyHistogram: View {
    let distribution: LatencyDistribution
    var color: Color = .cyan

    var body: some View {
        Canvas { context, size in
            let buckets = distribution.buckets
            guard !buckets.isEmpty else { return }
            let maxCount = max(1, buckets.map(\.count).max() ?? 1)
            let gap: CGFloat = 3
            let slot = size.width / CGFloat(buckets.count)
            let barWidth = max(1, slot - gap)
            for (index, bucket) in buckets.enumerated() {
                let fraction = CGFloat(bucket.count) / CGFloat(maxCount)
                let barHeight = fraction * size.height
                let originX = CGFloat(index) * slot
                let rect = CGRect(x: originX, y: size.height - barHeight, width: barWidth, height: barHeight)
                let fill = fraction > 0 ? color.opacity(0.75) : color.opacity(0.12)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(fill))
            }
        }
        .accessibilityLabel("Latency distribution histogram")
    }
}
