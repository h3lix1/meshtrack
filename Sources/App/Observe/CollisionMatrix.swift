// CollisionMatrix — pure analysis of node-id collisions that make relay-guessing
// ambiguous (G10). Meshtastic node ids are 4 bytes, but the relay hint
// (`MeshPacket.relay_node`) carries only the *last byte* of the previous hop.
// `PacketTraceBuilder.guessRelay` matches any node whose id ends in that byte and
// picks the one nearest the gateway — so whenever several nodes share a last byte,
// the guess is ambiguous. This module groups nodes by last byte (and by the
// 4-hex short id) to surface those collisions; the relay-confidence hint on the
// map is "1 / (candidates sharing the byte)". Pure + `Sendable`, fully tested.

import Domain
import Foundation

/// A node, reduced to just what collision analysis needs.
public struct CollisionNode: Sendable, Equatable, Identifiable {
    public let nodeNum: Int64
    public let name: String

    public var id: Int64 {
        nodeNum
    }

    public init(nodeNum: Int64, name: String) {
        self.nodeNum = nodeNum
        self.name = name
    }

    /// The relay byte = the last byte of the 4-byte id (what `relay_node` carries).
    public var lastByte: UInt8 {
        UInt8(truncatingIfNeeded: nodeNum)
    }

    /// The conventional 4-hex "short id" (the low 16 bits, e.g. `c3d4`). Meshtastic
    /// node short ids are the last two hex bytes of the `!aabbccdd` id.
    public var shortID: String {
        NodeID.shortHex(UInt32(truncatingIfNeeded: nodeNum))
    }

    /// The full `!aabbccdd` hex id.
    public var hexID: String {
        NodeID.hex(UInt32(truncatingIfNeeded: nodeNum))
    }
}

/// One collision bucket: the nodes that share a key (a last byte, or a short id).
public struct CollisionBucket: Sendable, Equatable, Identifiable {
    /// Display key for the bucket (e.g. `d4` for a last byte, `c3d4` for a short id).
    public let key: String
    /// The numeric byte value when this bucket is keyed by last byte (`0...255`);
    /// `nil` for short-id buckets. Drives the heatmap column index.
    public let byteValue: Int?
    public let nodes: [CollisionNode]

    public var id: String {
        key
    }

    public init(key: String, byteValue: Int?, nodes: [CollisionNode]) {
        self.key = key
        self.byteValue = byteValue
        self.nodes = nodes
    }

    /// How many nodes fall in this bucket.
    public var count: Int {
        nodes.count
    }

    /// A bucket collides when more than one node shares the key.
    public var isCollision: Bool {
        nodes.count > 1
    }
}

/// The full collision analysis over a node set.
public struct CollisionAnalysis: Sendable, Equatable {
    /// 256 buckets, one per possible last byte (`0x00...0xff`), index == byte value.
    /// Empty bytes are included (count 0) so the heatmap is a full 16×16 grid.
    public let lastByteBuckets: [CollisionBucket]
    /// Short-id buckets, only those that actually collide (>1 node), worst first.
    public let shortIDCollisions: [CollisionBucket]
    /// Total nodes analysed.
    public let nodeCount: Int

    public init(lastByteBuckets: [CollisionBucket], shortIDCollisions: [CollisionBucket], nodeCount: Int) {
        self.lastByteBuckets = lastByteBuckets
        self.shortIDCollisions = shortIDCollisions
        self.nodeCount = nodeCount
    }

    /// The largest number of nodes sharing any one last byte (the worst relay
    /// ambiguity). 0 for an empty fleet.
    public var maxLastByteCollision: Int {
        lastByteBuckets.map(\.count).max() ?? 0
    }

    /// How many distinct last bytes are shared by 2+ nodes (ambiguous relay bytes).
    public var collidingByteCount: Int {
        lastByteBuckets.count(where: \.isCollision)
    }

    /// Relay-guess confidence for `nodeNum`: `1 / (nodes sharing its last byte)`.
    /// A unique last byte → 1.0 (unambiguous); shared with N others → 1/(N+1).
    /// Returns `nil` for a node not in the analysed set.
    public func relayConfidence(forNodeNum nodeNum: Int64) -> Double? {
        let byte = Int(UInt8(truncatingIfNeeded: nodeNum))
        guard lastByteBuckets.indices.contains(byte) else { return nil }
        let bucket = lastByteBuckets[byte]
        guard bucket.nodes.contains(where: { $0.nodeNum == nodeNum }) else { return nil }
        return 1.0 / Double(bucket.count)
    }
}

/// Whether two nodes colliding on a relay byte are plausibly within radio earshot
/// of each other — i.e. whether the relay ambiguity is *physically* realisable. If
/// two nodes share a last byte but are 400 km apart, they can't both be the previous
/// hop into the same gateway, so the ambiguity is only nominal.
public enum EarshotRange: Sendable, Equatable {
    /// Both positions known and within the max-range threshold — the relay ambiguity
    /// is physically plausible.
    case inRange(meters: Double)
    /// Both positions known but beyond the threshold — they can't both be the hop.
    case outOfRange(meters: Double)
    /// One or both positions unknown — can't decide.
    case unknown

    /// The pair distance in metres, when both positions are known.
    public var meters: Double? {
        switch self {
        case let .inRange(meters), let .outOfRange(meters): meters
        case .unknown: nil
        }
    }
}

/// One earshot verdict for an ordered pair of colliding nodes (`a` before `b` by
/// `nodeNum`, matching bucket order).
public struct EarshotPair: Sendable, Equatable, Identifiable {
    public let a: CollisionNode
    public let b: CollisionNode
    public let range: EarshotRange

    /// Stable id: the two node numbers, smaller first.
    public var id: String {
        "\(a.nodeNum)-\(b.nodeNum)"
    }

    public init(a: CollisionNode, b: CollisionNode, range: EarshotRange) {
        self.a = a
        self.b = b
        self.range = range
    }
}

/// The pure earshot analyser. Classifies the pairwise relay ambiguity inside one
/// collision bucket as physically realisable or not, using last-known positions and
/// a configurable max-range threshold. `Sendable`, no I/O, unit-tested.
public enum Earshot {
    /// Default LoRa max-range threshold, in metres (~10 km). Meshtastic ground-level
    /// LoRa links are typically a few km in clutter and reach ~10 km with reasonable
    /// line-of-sight; record-breaking links go much further, but 10 km is a defensible
    /// "could plausibly be the same hop" cut-off for everyday terrain. Tune per fleet.
    public static let defaultMaxRangeMeters = 10000.0

    /// Classify a single pair given their (optional) last-known positions.
    public static func classify(
        a: GeoPoint?,
        b: GeoPoint?,
        maxRangeMeters: Double = defaultMaxRangeMeters
    ) -> EarshotRange {
        guard let a, let b else { return .unknown }
        let meters = Haversine.distanceMeters(from: a, to: b)
        return meters <= maxRangeMeters ? .inRange(meters: meters) : .outOfRange(meters: meters)
    }

    /// Every distinct ordered pair of nodes in `bucket`, classified by earshot. The
    /// bucket is already in ascending `nodeNum` order, so `a.nodeNum < b.nodeNum` for
    /// each pair. Positions are looked up by `nodeNum`; missing → `.unknown`. Returns
    /// `[]` for a non-colliding bucket (nothing to compare).
    public static func pairs(
        in bucket: CollisionBucket,
        positions: [Int64: GeoPoint],
        maxRangeMeters: Double = defaultMaxRangeMeters
    ) -> [EarshotPair] {
        guard bucket.nodes.count > 1 else { return [] }
        var result: [EarshotPair] = []
        let nodes = bucket.nodes
        for i in nodes.indices {
            for j in (i + 1) ..< nodes.count {
                let a = nodes[i]
                let b = nodes[j]
                let range = classify(
                    a: positions[a.nodeNum],
                    b: positions[b.nodeNum],
                    maxRangeMeters: maxRangeMeters
                )
                result.append(EarshotPair(a: a, b: b, range: range))
            }
        }
        return result
    }
}

/// The pure collision analyser.
public enum CollisionMatrix {
    /// Analyse `nodes`: group by last byte (full 256-bucket grid) and by short id
    /// (collisions only). Buckets keep nodes in ascending `nodeNum` order so the
    /// result is deterministic.
    public static func analyse(_ nodes: [CollisionNode]) -> CollisionAnalysis {
        let sorted = nodes.sorted { $0.nodeNum < $1.nodeNum }

        // Last-byte buckets — a full 0...255 grid (empty bytes included).
        var byByte: [[CollisionNode]] = Array(repeating: [], count: 256)
        for node in sorted {
            byByte[Int(node.lastByte)].append(node)
        }
        let lastByteBuckets = byByte.enumerated().map { index, members in
            CollisionBucket(
                key: String(format: "%02x", index),
                byteValue: index,
                nodes: members
            )
        }

        // Short-id collisions — only buckets where 2+ nodes share a 4-hex short id.
        var byShort: [String: [CollisionNode]] = [:]
        for node in sorted {
            byShort[node.shortID, default: []].append(node)
        }
        let shortIDCollisions = byShort
            .filter { $0.value.count > 1 }
            .map { CollisionBucket(key: $0.key, byteValue: nil, nodes: $0.value) }
            // Worst collisions first; ties broken by key for determinism.
            .sorted { ($0.count, $1.key) > ($1.count, $0.key) }

        return CollisionAnalysis(
            lastByteBuckets: lastByteBuckets,
            shortIDCollisions: shortIDCollisions,
            nodeCount: sorted.count
        )
    }
}
