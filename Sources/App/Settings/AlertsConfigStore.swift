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

    /// A sensible default threshold for a fresh rule, in the type's natural unit
    /// (% / volts / hours).
    public var defaultThreshold: Double {
        switch self {
        case .batteryBelow: 20
        case .voltageBelow: 3.3
        case .stale: 24
        }
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
    /// Threshold in the type's natural unit (% / volts / hours).
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
