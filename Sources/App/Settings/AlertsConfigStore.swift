// AlertsConfigStore — the storage contract for the Alert-rules configuration screen
// (SPEC §2.6). Defined here, in the App layer, so this screen does NOT depend on
// Persistence: the lead adapts the GRDB `alert_rule` table (SPEC §5:
// `alert_rule(id, scope, scope_id, type, params_json, enabled)`) to `AlertRuleStore`
// at integration. The record types are self-contained, `Codable` + `Sendable` value
// types that map 1:1 onto that table.
//
// Rule semantics mirror `RuleEngine`: scope precedence is node → class → global, and
// the threshold's unit depends on the type (% for battery_below, volts for
// voltage_below, seconds for stale).

import Domain
import Foundation

/// The rule types this screen edits — the ownership-sensitive, threshold-driven
/// subset of SPEC §2.6 (`battery_below`, `voltage_below`, `stale`). Raw values are
/// the persisted / scenario strings and match `RuleEngine.AlertType`.
public enum AlertRuleType: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    case batteryBelow = "battery_below"
    case voltageBelow = "voltage_below"
    case stale

    /// Human label for the editor.
    public var title: String {
        switch self {
        case .batteryBelow: "Battery below"
        case .voltageBelow: "Voltage below"
        case .stale: "Stale (silence)"
        }
    }

    /// Short unit suffix shown next to the threshold value.
    public var unit: String {
        switch self {
        case .batteryBelow: "%"
        case .voltageBelow: "V"
        case .stale: "h"
        }
    }

    /// A sensible default threshold for a fresh rule, in the type's *editor* unit
    /// (% / volts / hours).
    public var defaultThreshold: Double {
        switch self {
        case .batteryBelow: 20
        case .voltageBelow: 3.3
        case .stale: 24
        }
    }

    // MARK: Editor ↔ canonical (persisted/evaluated) unit conversion
    //
    // Finding 11: the editor shows the `stale` threshold in HOURS, but the canonical
    // value the engine evaluates (and that is persisted) is SECONDS — `RuleEvaluator`
    // compares a node's silence in seconds directly to the threshold. A raw 24 would
    // fire after 24 seconds, not 24 hours. So the `stale` threshold is converted at
    // the storage boundary: hours→seconds on the way down, seconds→hours on the way
    // back up. `battery_below` (%) and `voltage_below` (V) are unit-identical in both
    // domains and pass through untouched.

    /// Seconds-per-editor-unit for this type (`stale` is hours; the rest are 1:1).
    private var secondsPerEditorUnit: Double {
        switch self {
        case .stale: 3600
        case .batteryBelow, .voltageBelow: 1
        }
    }

    /// Convert an editor-unit threshold (e.g. 24 hours for `stale`) into the
    /// canonical seconds value the engine evaluates and the store persists.
    public func canonicalThreshold(fromEditor editorValue: Double) -> Double {
        editorValue * secondsPerEditorUnit
    }

    /// Convert a canonical (persisted seconds) threshold back into the editor unit
    /// (e.g. 86 400 seconds → 24 hours for `stale`) for display in the editor.
    public func editorThreshold(fromCanonical canonicalValue: Double) -> Double {
        canonicalValue / secondsPerEditorUnit
    }
}

/// The scope a rule applies to, in increasing precedence: global < class < node.
/// Mirrors `RuleEngine.RuleScope`; kept local so the screen is Persistence-free.
public enum AlertRuleScope: Sendable, Equatable, Hashable, Codable {
    case global
    case nodeClass(NodeClass)
    case node(UInt32)

    /// Ordering key for display (global first, then class, then node) and precedence.
    public var precedence: Int {
        switch self {
        case .global: 0
        case .nodeClass: 1
        case .node: 2
        }
    }

    /// A short label for the scope group header.
    public var title: String {
        switch self {
        case .global: "Global default"
        case let .nodeClass(nodeClass): "Class · \(nodeClass.rawValue)"
        case let .node(num): "Node · " + Self.hexID(num)
        }
    }

    static func hexID(_ num: UInt32) -> String {
        NodeID.hex(num)
    }
}

/// One typed alert rule record — the editor's unit of upsert/delete. Maps onto
/// `alert_rule(scope, scope_id, type, params_json, enabled)`: `scope`/`scope_id`
/// decompose `AlertRuleScope`, and `threshold` is the `params_json` payload.
public struct AlertRuleRecord: Sendable, Equatable, Hashable, Codable, Identifiable {
    public var scope: AlertRuleScope
    public var type: AlertRuleType
    /// Threshold in the type's *editor* unit (% / volts / **hours**). The canonical
    /// persisted/evaluated value is SECONDS for `stale`; `HoursToSecondsAlertRuleStore`
    /// converts at the storage boundary (Finding 11), so records flowing through the
    /// editor view model carry hours and the database holds seconds.
    public var threshold: Double
    public var enabled: Bool

    /// Stable identity = (scope, type): a node/class/global has at most one rule per
    /// type, so an upsert with the same identity replaces in place.
    public var id: String {
        "\(scopeKey(scope))|\(type.rawValue)"
    }

    public init(scope: AlertRuleScope, type: AlertRuleType, threshold: Double, enabled: Bool = true) {
        self.scope = scope
        self.type = type
        self.threshold = threshold
        self.enabled = enabled
    }

    /// True when `other` targets the same (scope, type) — i.e. is the same rule.
    public func matchesIdentity(of other: AlertRuleRecord) -> Bool {
        scope == other.scope && type == other.type
    }

    private func scopeKey(_ scope: AlertRuleScope) -> String {
        switch scope {
        case .global: "global"
        case let .nodeClass(nodeClass): "class:\(nodeClass.rawValue)"
        case let .node(num): "node:\(num)"
        }
    }
}

/// Port: lists / upserts / deletes alert-rule records, and reads/writes the global
/// default snooze. Self-contained so the Alerts config screen has no Persistence
/// dependency; the lead adapts `MeshStore` to it at integration. The fake
/// (`InMemoryAlertRuleStore`) lives in `SettingsFakes`.
///
/// The default-snooze accessors have default no-op/returning implementations so an
/// adapter that only stores rules still conforms; the in-memory fake overrides them.
public protocol AlertRuleStore: Sendable {
    /// All configured rules across every scope.
    func allRules() async throws -> [AlertRuleRecord]
    /// Insert or replace the rule with the same (scope, type) identity.
    func upsertRule(_ record: AlertRuleRecord) async throws
    /// Delete the rule for `(scope, type)`, if present.
    func deleteRule(scope: AlertRuleScope, type: AlertRuleType) async throws
    /// The default snooze duration (seconds) applied to a fresh alert snooze.
    func loadDefaultSnoozeSeconds() async throws -> Double
    /// Persist the default snooze duration (seconds).
    func saveDefaultSnoozeSeconds(_ seconds: Double) async throws
}

public extension AlertRuleStore {
    /// Default snooze when the adapter does not persist one (SPEC §2.6 cooldown/snooze).
    func loadDefaultSnoozeSeconds() async throws -> Double {
        3600
    }

    func saveDefaultSnoozeSeconds(_: Double) async throws {}
}

/// A unit-normalising `AlertRuleStore` decorator (Finding 11).
///
/// The Alerts editor works in *editor* units (`stale` in HOURS), but the canonical
/// value the rule engine evaluates and the database persists is SECONDS. This wraps
/// any underlying store and converts the `stale` threshold at the boundary:
/// **hours→seconds on `upsertRule`** (so what's persisted is canonical seconds — the
/// production adapter writes it verbatim, no change needed there) and
/// **seconds→hours on `allRules`** (so the editor displays hours). `battery_below`
/// and `voltage_below` are unit-identical and pass through unchanged, as do the
/// snooze accessors (already canonical seconds). The lead wires this between the
/// editor view model and the production `AlertRuleStore` at composition.
public struct HoursToSecondsAlertRuleStore: AlertRuleStore {
    private let wrapped: any AlertRuleStore

    public init(wrapping wrapped: any AlertRuleStore) {
        self.wrapped = wrapped
    }

    public func allRules() async throws -> [AlertRuleRecord] {
        try await wrapped.allRules().map(Self.toEditorUnits)
    }

    public func upsertRule(_ record: AlertRuleRecord) async throws {
        try await wrapped.upsertRule(Self.toCanonicalUnits(record))
    }

    public func deleteRule(scope: AlertRuleScope, type: AlertRuleType) async throws {
        try await wrapped.deleteRule(scope: scope, type: type)
    }

    public func loadDefaultSnoozeSeconds() async throws -> Double {
        try await wrapped.loadDefaultSnoozeSeconds()
    }

    public func saveDefaultSnoozeSeconds(_ seconds: Double) async throws {
        try await wrapped.saveDefaultSnoozeSeconds(seconds)
    }

    /// Editor → canonical: the threshold leaving the editor is in editor units;
    /// persist it as canonical seconds.
    private static func toCanonicalUnits(_ record: AlertRuleRecord) -> AlertRuleRecord {
        var canonical = record
        canonical.threshold = record.type.canonicalThreshold(fromEditor: record.threshold)
        return canonical
    }

    /// Canonical → editor: the threshold read from the store is canonical seconds;
    /// surface it in editor units for display.
    private static func toEditorUnits(_ record: AlertRuleRecord) -> AlertRuleRecord {
        var editor = record
        editor.threshold = record.type.editorThreshold(fromCanonical: record.threshold)
        return editor
    }
}
