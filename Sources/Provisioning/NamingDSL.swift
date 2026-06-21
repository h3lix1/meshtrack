// Naming DSL renderer + byte-limit validation (SPEC §2.1/§2.7).
//
// Templates like `{shortName}-{id[-4:]}` render to e.g. `baymesh-A123`. Tokens
// support Python-style slicing (`[-4:]`, `[:3]`, `[1:3]`). The renderer MUST
// validate the Meshtastic byte limits before any apply: short name ≤ 4 BYTES,
// long name ≤ 39 BYTES (UTF-8, not characters — emoji count their bytes). Pure.

/// Inputs available to a naming template.
public struct NamingContext: Sendable, Equatable {
    public let id: String
    public let shortName: String?
    public let longName: String?
    public let region: String?
    public let role: String?

    public init(
        id: String,
        shortName: String? = nil,
        longName: String? = nil,
        region: String? = nil,
        role: String? = nil
    ) {
        self.id = id
        self.shortName = shortName
        self.longName = longName
        self.region = region
        self.role = role
    }
}

public enum NameError: Error, Equatable, Sendable {
    case shortNameTooLong(bytes: Int, max: Int)
    case longNameTooLong(bytes: Int, max: Int)
    case unknownToken(String)
    case invalidSlice(String)
    case unterminatedToken
    case empty
}

public enum NamingDSL {
    public static let shortNameMaxBytes = 4
    public static let longNameMaxBytes = 39

    /// Render a template against `context` (no byte-limit check).
    public static func render(_ template: String, context: NamingContext) throws -> String {
        var result = ""
        var index = template.startIndex
        while index < template.endIndex {
            if template[index] == "{" {
                guard let close = template[index...].firstIndex(of: "}") else {
                    throw NameError.unterminatedToken
                }
                let spec = String(template[template.index(after: index) ..< close])
                result += try substitute(spec, context: context)
                index = template.index(after: close)
            } else {
                result.append(template[index])
                index = template.index(after: index)
            }
        }
        return result
    }

    /// Render and enforce the short-name byte limit (≤ 4 bytes).
    public static func renderShortName(_ template: String, context: NamingContext) throws -> String {
        try renderChecked(template, context: context, max: shortNameMaxBytes) {
            NameError.shortNameTooLong(bytes: $0, max: $1)
        }
    }

    /// Render and enforce the long-name byte limit (≤ 39 bytes).
    public static func renderLongName(_ template: String, context: NamingContext) throws -> String {
        try renderChecked(template, context: context, max: longNameMaxBytes) {
            NameError.longNameTooLong(bytes: $0, max: $1)
        }
    }

    private static func renderChecked(
        _ template: String,
        context: NamingContext,
        max: Int,
        tooLong: (Int, Int) -> NameError
    ) throws -> String {
        let name = try render(template, context: context)
        guard !name.isEmpty else { throw NameError.empty }
        let bytes = name.utf8.count
        guard bytes <= max else { throw tooLong(bytes, max) }
        return name
    }

    // MARK: - Token substitution

    private static func substitute(_ spec: String, context: NamingContext) throws -> String {
        guard let bracket = spec.firstIndex(of: "[") else {
            return try value(for: spec, context: context)
        }
        guard spec.hasSuffix("]") else { throw NameError.invalidSlice(spec) }
        let name = String(spec[..<bracket])
        let inner = String(spec[spec.index(after: bracket) ..< spec.index(before: spec.endIndex)])
        return try applySlice(value(for: name, context: context), spec: inner)
    }

    private static func value(for token: String, context: NamingContext) throws -> String {
        switch token {
        case "id": context.id
        case "shortName": context.shortName ?? ""
        case "longName": context.longName ?? ""
        case "region": context.region ?? ""
        case "role": context.role ?? ""
        default: throw NameError.unknownToken(token)
        }
    }

    /// Apply a Python-style `start:end` slice (either side may be empty; start may
    /// be negative for "from the end").
    private static func applySlice(_ value: String, spec: String) throws -> String {
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw NameError.invalidSlice(spec) }
        let chars = Array(value)
        let count = chars.count

        func resolve(_ token: Substring, fallback: Int) throws -> Int {
            if token.isEmpty { return fallback }
            guard let raw = Int(token) else { throw NameError.invalidSlice(spec) }
            return raw < 0 ? Swift.max(0, count + raw) : Swift.min(count, raw)
        }
        let start = try resolve(parts[0], fallback: 0)
        let end = try resolve(parts[1], fallback: count)
        guard start < end else { return "" }
        return String(chars[start ..< end])
    }
}
