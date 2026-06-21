// Lifecycle of a fired alert (SPEC §2.6 state machine) — the single source of
// truth. Persisted as TEXT via its rawValue.

public enum AlertState: String, Codable, Sendable, Equatable, CaseIterable {
    case firing
    case acknowledged
    case resolved
}
