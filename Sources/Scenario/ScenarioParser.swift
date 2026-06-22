// The scenario DSL parser: YAML text → typed `ScenarioSuite`.
//
// Parsing uses Yams to load the document into a generic node tree, then walks
// that tree with explicit, typed validation. We deliberately do *not* lean on
// Codable here: the fix-offset is a union (`dlat`/`dlon` vs `meters_from_anchor`)
// and we want precise, node-scoped errors (`ScenarioParseError`) rather than the
// opaque messages a synthesized decoder would produce.
//
// See `SCHEMA.md` for the concrete schema this parser accepts.

import Yams

/// Parses scenario YAML into the typed model. Stateless and `Sendable`; one
/// shared instance is fine to reuse across threads.
public struct ScenarioParser: Sendable {
    public init() {}

    /// Parse a full scenario document (a YAML list of node scenarios).
    ///
    /// - Throws: ``ScenarioParseError`` for any malformed or invalid input.
    public func parse(yaml: String) throws -> ScenarioSuite {
        let loaded: Any?
        do {
            loaded = try Yams.load(yaml: yaml)
        } catch {
            throw ScenarioParseError.malformedYAML(String(describing: error))
        }

        // An empty document (or one that is only comments) loads as nil; treat
        // it as an empty suite rather than an error.
        guard let root = loaded else {
            return ScenarioSuite(scenarios: [])
        }
        guard let entries = root as? [Any] else {
            throw ScenarioParseError.rootNotSequence
        }

        let scenarios = try entries.enumerated().map { index, entry -> Scenario in
            guard let mapping = Self.asMapping(entry) else {
                throw ScenarioParseError.entryNotMapping(index: index)
            }
            return try Self.parseScenario(mapping)
        }
        return ScenarioSuite(scenarios: scenarios)
    }

    // MARK: - Scenario entry

    private static func parseScenario(_ mapping: [String: Any]) throws -> Scenario {
        // `node` is the only hard-required key; everything else is optional.
        let node = try requireString(mapping, key: "node", node: "<unnamed>")

        let nodeClass = try parseNodeClass(mapping, node: node)
        let arm = try parseArm(mapping, node: node)
        let fixes = try parseFixes(mapping, node: node)
        let silenceHours = try optionalDouble(mapping, key: "silence_hours", node: node)
        // ADR 0008: omitted `managed` defaults to managed (single-fleet); declare
        // `managed: false` to assert a stranger's node is never alerted.
        let isManaged = try optionalBool(mapping, key: "managed", node: node) ?? true
        let expected = try parseExpectedAlerts(mapping, node: node)

        return Scenario(
            node: node,
            nodeClass: nodeClass,
            arm: arm,
            fixes: fixes,
            silenceHours: silenceHours,
            isManaged: isManaged,
            expectedAlerts: expected
        )
    }

    private static func parseNodeClass(
        _ mapping: [String: Any],
        node: String
    ) throws -> NodeClass? {
        guard let raw = mapping["class"] else { return nil }
        guard let string = raw as? String else {
            throw ScenarioParseError.wrongType(key: "class", node: node, expected: "string")
        }
        guard let value = NodeClass(rawValue: string) else {
            throw ScenarioParseError.invalidEnum(
                key: "class",
                node: node,
                value: string,
                allowed: NodeClass.allCases.map(\.rawValue)
            )
        }
        return value
    }

    // MARK: - Arm

    private static func parseArm(_ mapping: [String: Any], node: String) throws -> ArmConfig? {
        guard let raw = mapping["arm"] else { return nil }
        guard let arm = asMapping(raw) else {
            throw ScenarioParseError.wrongType(key: "arm", node: node, expected: "mapping")
        }
        let threshold = try requireDouble(arm, key: "threshold_m", node: node)
        let margin = try optionalDouble(arm, key: "accuracy_margin_m", node: node)
            ?? ArmConfig.defaultAccuracyMarginMeters
        let confirmation = try optionalInt(arm, key: "confirmation_count", node: node)
            ?? ArmConfig.defaultConfirmationCount
        let escape = try optionalDouble(arm, key: "escape_factor", node: node)
            ?? ArmConfig.defaultEscapeFactor
        return ArmConfig(
            thresholdMeters: threshold,
            accuracyMarginMeters: margin,
            confirmationCount: confirmation,
            escapeFactor: escape
        )
    }

    // MARK: - Fixes

    private static func parseFixes(_ mapping: [String: Any], node: String) throws -> [FixStep] {
        guard let raw = mapping["fixes"] else { return [] }
        guard let list = raw as? [Any] else {
            throw ScenarioParseError.wrongType(key: "fixes", node: node, expected: "sequence")
        }
        return try list.map { try parseFixStep($0, node: node) }
    }

    private static func parseFixStep(_ entry: Any, node: String) throws -> FixStep {
        guard let fix = asMapping(entry) else {
            throw ScenarioParseError.wrongType(key: "fixes[]", node: node, expected: "mapping")
        }
        let offset = try parseFixOffset(fix, node: node)
        let count = try optionalInt(fix, key: "count", node: node) ?? FixStep.defaultCount
        guard count >= 1 else {
            throw ScenarioParseError.invalidNumber(
                key: "count",
                node: node,
                reason: "must be >= 1"
            )
        }
        return FixStep(offset: offset, count: count)
    }

    private static func parseFixOffset(_ fix: [String: Any], node: String) throws -> FixOffset {
        let hasMeters = fix["meters_from_anchor"] != nil
        let hasDlat = fix["dlat"] != nil
        let hasDlon = fix["dlon"] != nil

        switch (hasMeters, hasDlat || hasDlon) {
        case (true, true):
            throw ScenarioParseError.ambiguousFixOffset(
                node: node,
                detail: "set meters_from_anchor OR dlat/dlon, not both"
            )
        case (false, false):
            throw ScenarioParseError.ambiguousFixOffset(
                node: node,
                detail: "set meters_from_anchor OR dlat+dlon"
            )
        case (true, false):
            let meters = try requireDouble(fix, key: "meters_from_anchor", node: node)
            let accuracy = try requireDouble(fix, key: "h_accuracy", node: node)
            return .metersFromAnchor(meters, horizontalAccuracyMeters: accuracy)
        case (false, true):
            guard hasDlat, hasDlon else {
                throw ScenarioParseError.ambiguousFixOffset(
                    node: node,
                    detail: "delta form needs both dlat and dlon"
                )
            }
            let dlat = try requireDouble(fix, key: "dlat", node: node)
            let dlon = try requireDouble(fix, key: "dlon", node: node)
            let accuracy = try requireDouble(fix, key: "h_accuracy", node: node)
            return .delta(dlat: dlat, dlon: dlon, horizontalAccuracyMeters: accuracy)
        }
    }

    // MARK: - Expected alerts

    private static func parseExpectedAlerts(
        _ mapping: [String: Any],
        node: String
    ) throws -> [ExpectedAlert] {
        guard let raw = mapping["expect_alerts"] else { return [] }
        guard let list = raw as? [Any] else {
            throw ScenarioParseError.wrongType(
                key: "expect_alerts",
                node: node,
                expected: "sequence"
            )
        }
        return try list.map { entry in
            guard let item = asMapping(entry) else {
                throw ScenarioParseError.wrongType(
                    key: "expect_alerts[]",
                    node: node,
                    expected: "mapping"
                )
            }
            let type = try requireString(item, key: "type", node: node)
            let count = try requireInt(item, key: "count", node: node)
            guard count >= 0 else {
                throw ScenarioParseError.invalidNumber(
                    key: "count",
                    node: node,
                    reason: "must be >= 0"
                )
            }
            return ExpectedAlert(type: type, count: count)
        }
    }
}

// MARK: - Generic value helpers

/// Value-coercion utilities shared across the typed parse steps. Kept in an
/// extension so the core parser body stays focused (and within lint limits).
extension ScenarioParser {
    /// Yams may hand back `[String: Any]` or `[AnyHashable: Any]`; normalise to
    /// `[String: Any]` (dropping any non-string keys, which the schema never uses).
    private static func asMapping(_ value: Any) -> [String: Any]? {
        if let direct = value as? [String: Any] {
            return direct
        }
        guard let anyKeyed = value as? [AnyHashable: Any] else { return nil }
        var result: [String: Any] = [:]
        for (key, element) in anyKeyed {
            guard let stringKey = key as? String else { continue }
            result[stringKey] = element
        }
        return result
    }

    private static func requireString(
        _ mapping: [String: Any],
        key: String,
        node: String
    ) throws -> String {
        guard let raw = mapping[key] else {
            throw ScenarioParseError.missingKey(key, node: node)
        }
        guard let value = raw as? String else {
            throw ScenarioParseError.wrongType(key: key, node: node, expected: "string")
        }
        return value
    }

    private static func requireDouble(
        _ mapping: [String: Any],
        key: String,
        node: String
    ) throws -> Double {
        guard let raw = mapping[key] else {
            throw ScenarioParseError.missingKey(key, node: node)
        }
        guard let value = doubleValue(raw) else {
            throw ScenarioParseError.wrongType(key: key, node: node, expected: "number")
        }
        guard value.isFinite else {
            throw ScenarioParseError.invalidNumber(key: key, node: node, reason: "not finite")
        }
        return value
    }

    private static func optionalDouble(
        _ mapping: [String: Any],
        key: String,
        node: String
    ) throws -> Double? {
        guard mapping[key] != nil else { return nil }
        return try requireDouble(mapping, key: key, node: node)
    }

    private static func requireInt(
        _ mapping: [String: Any],
        key: String,
        node: String
    ) throws -> Int {
        guard let raw = mapping[key] else {
            throw ScenarioParseError.missingKey(key, node: node)
        }
        guard let value = intValue(raw) else {
            throw ScenarioParseError.wrongType(key: key, node: node, expected: "integer")
        }
        return value
    }

    private static func optionalInt(
        _ mapping: [String: Any],
        key: String,
        node: String
    ) throws -> Int? {
        guard mapping[key] != nil else { return nil }
        return try requireInt(mapping, key: key, node: node)
    }

    private static func optionalBool(
        _ mapping: [String: Any],
        key: String,
        node: String
    ) throws -> Bool? {
        guard let raw = mapping[key] else { return nil }
        guard let value = raw as? Bool else {
            throw ScenarioParseError.wrongType(key: key, node: node, expected: "boolean")
        }
        return value
    }

    /// Accept `Int` and `Double` scalars as a `Double`. Yams types integral
    /// literals as `Int`, so `threshold_m: 100` must still satisfy a Double field.
    private static func doubleValue(_ raw: Any) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        return nil
    }

    /// Accept an `Int`, or a `Double` that is exactly integral, as an `Int`.
    private static func intValue(_ raw: Any) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? Double, value.rounded() == value, value.isFinite {
            return Int(value)
        }
        return nil
    }
}
