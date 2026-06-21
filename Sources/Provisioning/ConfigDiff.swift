// Config diff (SPEC §2.7): every apply is dry-run first — render the desired
// config, diff it against the node's current config, and require explicit confirm
// before applying. The diff is pure; an empty diff means the apply is idempotent
// (nothing to do).

/// One field that differs between desired and current config.
public struct ConfigChange: Sendable, Equatable {
    public let field: String
    public let from: String?
    public let to: String

    public init(field: String, from: String?, to: String) {
        self.field = field
        self.from = from
        self.to = to
    }
}

public enum ConfigDiff {
    /// The changes needed to bring `current` to `desired`, in stable field order.
    /// Empty when the node already matches (idempotent no-op).
    public static func changes(desired: [String: String], current: [String: String]) -> [ConfigChange] {
        desired.sorted { $0.key < $1.key }.compactMap { field, value in
            current[field] == value ? nil : ConfigChange(field: field, from: current[field], to: value)
        }
    }
}
