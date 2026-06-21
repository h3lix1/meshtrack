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
