// Node classification (SPEC §2.1) — the single source of truth.
//
// Class drives default alert behaviour, is user-overridable, and may be inferred
// (a node whose position never changes for K days → suggest `fixed`). Persisted
// as TEXT via its rawValue. `Codable` is standard-library, so Domain stays pure.

public enum NodeClass: String, Codable, Sendable, Equatable, CaseIterable {
    case fixed
    case mobile
    case gateway
    case unknown
}
