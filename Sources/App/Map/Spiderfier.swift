// Spiderfier — pure geometry for fanning out co-located map annotations (Task 3).
//
// Several mesh nodes routinely share (nearly) the same coordinate — a site with a
// gateway and a couple of fixed nodes bolted to the same mast — so even fully zoomed
// in their markers stack and only the top one is reachable. This computes, for a set
// of points that project to (almost) the same screen pixel, a displaced screen
// position for each: fanned evenly around a small circle, with a leader line back to
// the shared true point.
//
// It is deliberately MapKit-free (operates on CGPoints + ids) so it can be unit-tested
// headless and reused by either the MKAnnotation substrate (offsetting the views) or
// the Canvas overlay. The caller decides "sufficient zoom" by only invoking spiderfy
// when the cluster's on-screen spread is below `proximityThreshold`.

import CoreGraphics
import Foundation

/// One node's placement after spiderfying: where to draw its marker, and the true
/// anchor a leader line returns to. `isFanned` is false for a node that wasn't part of
/// a co-located group (its displaced point equals its anchor).
public struct SpiderfiedPlacement: Equatable, Sendable {
    public let id: Int64
    /// The true projected point (cluster centre for a fanned node).
    public let anchor: CGPoint
    /// Where the marker should actually be drawn.
    public let displaced: CGPoint
    /// Whether this node was fanned out (part of a co-located group of 2+).
    public let isFanned: Bool

    public init(id: Int64, anchor: CGPoint, displaced: CGPoint, isFanned: Bool) {
        self.id = id
        self.anchor = anchor
        self.displaced = displaced
        self.isFanned = isFanned
    }
}

public enum Spiderfier {
    /// Pixel radius nodes are fanned out to around the shared anchor.
    public static let defaultRadius: CGFloat = 34
    /// Two points closer than this (pixels) are treated as co-located.
    public static let defaultProximity: CGFloat = 14

    /// Fan out groups of points that fall within `proximity` pixels of each other.
    ///
    /// - Points in a group of one are returned unchanged (`isFanned == false`,
    ///   displaced == anchor).
    /// - A group of N≥2 shares an anchor at the group's centroid; each member is placed
    ///   evenly around a circle of `radius` about that centroid. The angular order is
    ///   sorted by id so the layout is stable frame-to-frame.
    public static func spiderfy(
        points: [(id: Int64, point: CGPoint)],
        radius: CGFloat = defaultRadius,
        proximity: CGFloat = defaultProximity
    ) -> [SpiderfiedPlacement] {
        let groups = cluster(points: points, proximity: proximity)
        var result: [SpiderfiedPlacement] = []
        for group in groups {
            if group.count == 1, let only = group.first {
                result.append(SpiderfiedPlacement(
                    id: only.id, anchor: only.point, displaced: only.point, isFanned: false
                ))
                continue
            }
            let anchor = centroid(group.map(\.point))
            let ordered = group.sorted { $0.id < $1.id }
            let step = (2 * Double.pi) / Double(ordered.count)
            for (index, member) in ordered.enumerated() {
                // Start at -90° (straight up) so the fan reads naturally.
                let angle = -Double.pi / 2 + step * Double(index)
                let displaced = CGPoint(
                    x: anchor.x + radius * CGFloat(cos(angle)),
                    y: anchor.y + radius * CGFloat(sin(angle))
                )
                result.append(SpiderfiedPlacement(
                    id: member.id, anchor: anchor, displaced: displaced, isFanned: true
                ))
            }
        }
        return result
    }

    /// Single-link clustering: any point within `proximity` of an existing group joins
    /// it (transitive). O(n²) — fine for the dozens of annotations a map ever shows.
    static func cluster(
        points: [(id: Int64, point: CGPoint)],
        proximity: CGFloat
    ) -> [[(id: Int64, point: CGPoint)]] {
        var groups: [[(id: Int64, point: CGPoint)]] = []
        for entry in points {
            if let index = groups.firstIndex(where: { group in
                group.contains { distance($0.point, entry.point) <= proximity }
            }) {
                groups[index].append(entry)
            } else {
                groups.append([entry])
            }
        }
        return groups
    }

    private static func centroid(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    private static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let deltaX = lhs.x - rhs.x
        let deltaY = lhs.y - rhs.y
        return (deltaX * deltaX + deltaY * deltaY).squareRoot()
    }
}
