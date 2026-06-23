// VizLegend — the pure data behind the viz-settings legend (SPEC §1.4 colour key,
// §1.3 guessed-vs-observed key + relay-confidence hint). Kept separate from the
// SwiftUI panel so the mapping (packet id → colour/label, and the per-trace guessed
// confidence) is deterministic and unit-tested; the panel just lays it out.

import Domain
import SwiftUI

public enum VizLegend {
    /// One row of the per-packet-id colour legend.
    public struct Entry: Identifiable, Sendable, Equatable {
        public let id: UInt32
        public let color: Color
        /// "#a1b2c3d4" — the packet id as hex.
        public let label: String
        /// Number of hop edges in the trace (observed + guessed).
        public let hops: Int
        /// How many of this trace's edges were guessed from the relay byte.
        public let guessedEdges: Int

        public init(id: UInt32, color: Color, label: String, hops: Int, guessedEdges: Int) {
            self.id = id
            self.color = color
            self.label = label
            self.hops = hops
            self.guessedEdges = guessedEdges
        }
    }

    /// Build legend rows for the currently-animating traces, ordered by id.
    public static func entries(for traces: [PacketTrace]) -> [Entry] {
        traces
            .map { trace in
                Entry(
                    id: trace.id,
                    color: PacketColor.color(for: trace.id),
                    label: hexLabel(trace.id),
                    hops: trace.hops,
                    guessedEdges: trace.edges.count(where: { $0.kind == .guessed })
                )
            }
            .sorted { $0.id < $1.id }
    }

    /// "#a1b2c3d4" for a packet id.
    public static func hexLabel(_ id: UInt32) -> String {
        "#" + String(format: "%08x", id)
    }

    /// One row of the focused packet's "received by (reported)" list — a receiver we have
    /// evidence heard the packet, drawn on the map OR (when unpositioned) only listable here.
    public struct ReceiverRow: Identifiable, Sendable, Equatable {
        public let nodeID: Int64
        /// Hop at which it received the packet (0 = unknown).
        public let hop: Int
        public let kind: TraceReceiver.Kind
        /// True when this node has a known position and is also ringed on the map; false
        /// when it could only be listed (no position to draw).
        public let onMap: Bool

        public var id: Int64 {
            nodeID
        }

        /// "!a1b2c3d4" — the Meshtastic node-id convention (last 32 bits, hex).
        public var label: String {
            "!" + String(format: "%08x", UInt32(truncatingIfNeeded: nodeID))
        }

        /// A short role word for the row, honest about how we know it received the packet.
        public var roleLabel: String {
            switch kind {
            case .gateway: "gateway"
            case .relay: "relay \u{2248}" // guessed
            case .destination: "destination"
            }
        }

        public init(nodeID: Int64, hop: Int, kind: TraceReceiver.Kind, onMap: Bool) {
            self.nodeID = nodeID
            self.hop = hop
            self.kind = kind
            self.onMap = onMap
        }
    }

    /// The complete "received by (reported)" roster for the focused packet: every receiver
    /// we have evidence for — those ringed on the map AND those we could only list because
    /// we have no position for them (item 8 §2) — so "all receivers" is genuinely complete.
    ///
    /// HONESTY: this is every receiver we have EVIDENCE for (reporting gateways, guessed
    /// relays, addressed destination), NOT every node that physically overheard the packet —
    /// the mesh never reports silent overhearers, so they are unknowable. The "(reported)"
    /// qualifier in the UI heading reflects that.
    public static func receivedBy(_ trace: PacketTrace) -> [ReceiverRow] {
        let onMapRows = trace.receivers.map {
            ReceiverRow(nodeID: $0.nodeID, hop: $0.hop, kind: $0.kind, onMap: true)
        }
        let listedRows = trace.unpositionedReceivers.map {
            ReceiverRow(nodeID: $0.nodeID, hop: $0.hop, kind: $0.kind, onMap: false)
        }
        return (onMapRows + listedRows).sorted {
            $0.hop != $1.hop ? $0.hop < $1.hop : $0.nodeID < $1.nodeID
        }
    }

    /// A human relay-confidence sentence for a candidate count — surfaced in the
    /// guessed key (SPEC §1.3 "how many candidate nodes shared the relay byte").
    public static func confidenceHint(candidateCount: Int) -> String {
        switch RelayConfidence.level(forCandidateCount: candidateCount) {
        case .none:
            "no candidate shared the relay byte"
        case .high:
            "1 node shared the relay byte — high confidence"
        case .medium, .low:
            "\(candidateCount) nodes shared the relay byte — \(candidateCount) candidates"
        }
    }
}
