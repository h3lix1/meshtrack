// Typed errors for scenario parsing.
//
// Per AGENTS.md every failure is a typed error (no `fatalError`, no untyped
// `throw`). Each case carries enough context — which node, which field — to make
// a malformed scenario file diagnosable from the message alone.

/// A failure encountered while parsing a scenario YAML document.
public enum ScenarioParseError: Error, Equatable, Sendable {
    /// The YAML was syntactically invalid (Yams could not load it). The
    /// associated string is Yams' own description, preserved for the operator.
    case malformedYAML(String)

    /// The document root was not the expected sequence of scenario mappings.
    case rootNotSequence

    /// A scenario entry was not a mapping (e.g. a bare scalar in the list).
    case entryNotMapping(index: Int)

    /// A required key was missing from a scenario or one of its sub-mappings.
    case missingKey(String, node: String)

    /// A value had the wrong shape/type for its key.
    case wrongType(key: String, node: String, expected: String)

    /// An enum-valued field held a value outside its allowed set.
    case invalidEnum(key: String, node: String, value: String, allowed: [String])

    /// A numeric field held a non-finite or out-of-range value.
    case invalidNumber(key: String, node: String, reason: String)

    /// A fix step did not select exactly one offset form (it had neither, both,
    /// or a partial set of the `dlat`/`dlon` vs `meters_from_anchor` keys).
    case ambiguousFixOffset(node: String, detail: String)
}

extension ScenarioParseError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .malformedYAML(message):
            "malformed YAML: \(message)"
        case .rootNotSequence:
            "scenario document root must be a sequence (a YAML list of node scenarios)"
        case let .entryNotMapping(index):
            "scenario entry #\(index) is not a mapping"
        case let .missingKey(key, node):
            "node '\(node)': missing required key '\(key)'"
        case let .wrongType(key, node, expected):
            "node '\(node)': key '\(key)' has the wrong type (expected \(expected))"
        case let .invalidEnum(key, node, value, allowed):
            "node '\(node)': key '\(key)' value '\(value)' is invalid "
                + "(allowed: \(allowed.joined(separator: ", ")))"
        case let .invalidNumber(key, node, reason):
            "node '\(node)': key '\(key)' is not a valid number (\(reason))"
        case let .ambiguousFixOffset(node, detail):
            "node '\(node)': fix step offset is ambiguous — \(detail)"
        }
    }
}
