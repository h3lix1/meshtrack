// CollisionMatrixComponents — the row + cell subviews for `CollisionMatrixView`
// (G10), split out so the view file stays within the lint file-length cap. All
// bespoke shapes + `Text` (NOT `Canvas`/stock controls) so the matrix hit-tests for
// the click-through and renders faithfully in headless `ImageRenderer` snapshots.

import SwiftUI

/// One short-id collision row: the short id + the colliding node names.
struct CollisionRow: View {
    let bucket: CollisionBucket

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(bucket.key)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.orange)
                .frame(width: 44, alignment: .leading)
            Text(bucket.nodes.map(\.name).joined(separator: ", "))
                .font(.system(size: 12)).foregroundStyle(.white)
            Spacer()
            Text("×\(bucket.count)")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
}

/// One node row in the click-through panel: name, full `!aabbccdd` id, 4-hex short
/// id, and the relay-guess confidence (`1 / candidates`).
struct CollisionNodeRow: View {
    let node: CollisionNode
    let confidence: Double?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(node.name)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 90, alignment: .leading)
            Text(node.hexID)
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            Text(node.shortID)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.orange)
            Spacer()
            if let confidence {
                Text("conf \(String(format: "%.2f", confidence))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(confidence < 1.0 ? .orange : .secondary)
            }
        }
    }
}

/// One earshot pair row: the two short ids, the great-circle distance, and the
/// in-range / out-of-range / unknown verdict.
struct EarshotPairRow: View {
    let pair: EarshotPair

    var body: some View {
        HStack(spacing: 8) {
            Text("\(pair.nodeA.shortID) ↔ \(pair.nodeB.shortID)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
            Spacer()
            Text(verdict)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    private var verdict: String {
        switch pair.range {
        case let .inRange(meters): "\(Self.km(meters)) — in range"
        case let .outOfRange(meters): "\(Self.km(meters)) — out of range"
        case .unknown: "position unknown"
        }
    }

    private var color: Color {
        switch pair.range {
        case .inRange: .green
        case .outOfRange: .orange
        case .unknown: .secondary
        }
    }

    /// Metres → a compact "2.3 km" / "640 m" label.
    private static func km(_ meters: Double) -> String {
        meters >= 1000
            ? String(format: "%.1f km", meters / 1000)
            : String(format: "%.0f m", meters)
    }
}

/// The 16×16 last-byte heatmap, rendered as a bespoke `Grid` of shape-backed cells
/// (NOT `Canvas`/stock controls) so it both hit-tests for the click-through and stays
/// faithful in headless `ImageRenderer` snapshots. Cell intensity tracks the number
/// of nodes sharing that byte; occupied cells show the byte value (and count when
/// colliding); a cell with 2+ nodes (an ambiguous relay byte) is outlined, and the
/// selected cell is highlighted. Tapping a colliding cell calls `onTap`.
struct CollisionHeatmap: View {
    let buckets: [CollisionBucket]
    var selectedByte: Int?
    var onTap: ((Int) -> Void)?

    private static let cols = 16
    private static let rows = 16

    private var maxCount: Int {
        max(buckets.map(\.count).max() ?? 0, 1)
    }

    var body: some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            ForEach(0 ..< Self.rows, id: \.self) { row in
                GridRow {
                    ForEach(0 ..< Self.cols, id: \.self) { col in
                        let value = row * Self.cols + col
                        CollisionCell(
                            bucket: bucketFor(value),
                            value: value,
                            maxCount: maxCount,
                            isSelected: selectedByte == value
                        )
                        .onTapGesture { onTap?(value) }
                    }
                }
            }
        }
    }

    private func bucketFor(_ value: Int) -> CollisionBucket? {
        buckets.indices.contains(value) ? buckets[value] : nil
    }
}

/// A single heatmap cell: a rounded rect coloured by occupancy, with the byte value
/// (and node count when colliding) drawn legibly on top. Bespoke shapes + `Text` keep
/// it crisp headless.
private struct CollisionCell: View {
    let bucket: CollisionBucket?
    let value: Int
    let maxCount: Int
    let isSelected: Bool

    private var nodeCount: Int {
        bucket?.count ?? 0
    }

    private var isCollision: Bool {
        nodeCount > 1
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(strokeColor, lineWidth: strokeWidth)
            )
            .overlay(label)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
    }

    /// Byte value in hex, with the node count beneath when 2+ share it. Empty cells
    /// stay blank so the grid reads as a heatmap, not a wall of zeros.
    @ViewBuilder private var label: some View {
        if !isEmpty {
            VStack(spacing: 0) {
                Text(String(format: "%02x", value))
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                if isCollision {
                    Text("×\(nodeCount)")
                        .font(.system(size: 7, weight: .heavy, design: .monospaced))
                }
            }
            .foregroundStyle(.white)
            .minimumScaleFactor(0.5)
        }
    }

    private var isEmpty: Bool {
        nodeCount == 0
    }

    private var fillColor: Color {
        guard !isEmpty else { return .white.opacity(0.04) }
        let intensity = Double(nodeCount) / Double(maxCount)
        // Single occupant = cool/safe; collisions warm toward red.
        let hue = isCollision ? 0.02 : 0.55
        return Color(hue: hue, saturation: 0.85, brightness: 1.0)
            .opacity(0.25 + 0.7 * intensity)
    }

    private var strokeColor: Color {
        if isSelected { return .white }
        return isCollision ? .white.opacity(0.7) : .clear
    }

    private var strokeWidth: CGFloat {
        isSelected ? 2 : (isCollision ? 1 : 0)
    }
}
