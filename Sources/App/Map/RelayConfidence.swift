// RelayConfidence — the "how sure are we about this guessed hop?" hint for the
// viz-settings key (SPEC §1.3). The previous hop is GUESSED from the relay-node
// byte: any node whose id ends in that byte is a candidate, and the builder picks
// the one nearest the gateway. The *more* nodes that share the byte, the *less*
// confident that pick is. This pure helper counts the candidates so the UI can say
// e.g. "≈ guessed — 1 of 4 nodes shared the relay byte".
//
// Pure (no MapKit/SwiftUI); unit-tested. Mirrors the filter inside
// PacketTraceBuilder.guessRelay so the surfaced confidence matches the actual guess.

import Domain

public enum RelayConfidence {
    /// Number of known-position nodes whose id's last byte equals `relayByte`
    /// (excluding `excluding`). 1 = unambiguous; 0 = no candidate (edge stays
    /// observed); >1 = ambiguous, confidence drops as the count grows.
    public static func candidateCount(
        relayByte: UInt8,
        excluding: Set<Int64> = [],
        positions: [Int64: GeoPoint]
    ) -> Int {
        positions.keys
            .count(where: { UInt8(truncatingIfNeeded: $0) == relayByte && !excluding.contains($0) })
    }

    /// A confidence level derived from the candidate count, for colouring the key.
    public enum Level: Sendable, Equatable {
        /// No candidate shared the byte — the edge was drawn observed, not guessed.
        case none
        /// Exactly one candidate — the guess is unambiguous.
        case high
        /// Two or three candidates — plausible but uncertain.
        case medium
        /// Four or more candidates — low confidence.
        case low
    }

    public static func level(forCandidateCount count: Int) -> Level {
        switch count {
        case ..<1: .none
        case 1: .high
        case 2, 3: .medium
        default: .low
        }
    }
}
