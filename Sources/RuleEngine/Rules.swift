// Data-driven alert rules + config hierarchy (SPEC §2.6).
//
// Rules are typed records, not code branches. The effective rule for a node is
// resolved by precedence: per-node override → node-class default → global default.

import Domain

/// Every alert kind (SPEC §2.6). Raw values are the persisted/scenario strings.
public enum AlertType: String, Sendable, Equatable, CaseIterable {
    case moved
    case returned
    case geofenceExit = "geofence_exit"
    case stale
    case batteryBelow = "battery_below"
    case voltageBelow = "voltage_below"
    case channelUtilHigh = "channel_util_high"
    case newNodeSeen = "new_node_seen"
    case backOnline = "back_online"
}

/// The scope a rule applies to, in increasing precedence: global < class < node.
public enum RuleScope: Sendable, Equatable, Hashable {
    case global
    case nodeClass(NodeClass)
    case node(UInt32)
}

/// One typed alert rule.
public struct AlertRule: Sendable, Equatable {
    public let type: AlertType
    public let scope: RuleScope
    /// Threshold in the rule's natural unit (seconds for `stale`, % for
    /// `battery_below`, volts for `voltage_below`). `0` for `stale` means "use the
    /// node's expected interval".
    public let threshold: Double
    public let enabled: Bool
    public let cooldownSeconds: Double

    public init(
        type: AlertType,
        scope: RuleScope,
        threshold: Double,
        enabled: Bool = true,
        cooldownSeconds: Double = 0
    ) {
        self.type = type
        self.scope = scope
        self.threshold = threshold
        self.enabled = enabled
        self.cooldownSeconds = cooldownSeconds
    }
}

/// A collection of rules with hierarchy resolution.
public struct RuleSet: Sendable, Equatable {
    public let rules: [AlertRule]

    public init(_ rules: [AlertRule]) {
        self.rules = rules
    }

    /// The effective rule for `type` for a node, by precedence
    /// node → class → global. Disabled rules are ignored.
    public func effectiveRule(type: AlertType, nodeNum: UInt32, nodeClass: NodeClass) -> AlertRule? {
        let candidates = rules.filter { $0.type == type && $0.enabled }
        return candidates.first { $0.scope == .node(nodeNum) }
            ?? candidates.first { $0.scope == .nodeClass(nodeClass) }
            ?? candidates.first { $0.scope == .global }
    }
}
