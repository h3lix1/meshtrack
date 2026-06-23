// AlertConsoleItem — one alert formatted for the alerts console. Split out of
// `AlertsConsoleViewModel` so the view model file stays within the lint limit.

import Domain
import RuleEngine

/// One alert formatted for the console. Carries the live engine `Alert` plus the
/// derived, time-relative facts the view renders (cooldown / snooze remaining).
public struct AlertConsoleItem: Sendable, Equatable, Identifiable {
    public var id: String {
        "\(type.rawValue)#\(nodeNum)"
    }

    public let type: AlertType
    public let nodeNum: Int64
    public let nodeName: String
    public let detail: String
    public let state: AlertState
    public let firedAt: Instant
    /// Seconds until a *resolved* alert is eligible to re-fire (cooldown), or nil
    /// when not resolved / no cooldown pending.
    public let cooldownRemaining: Double?
    /// Seconds until an active snooze expires, or nil when not snoozed.
    public let snoozeRemaining: Double?

    /// Higher = more urgent. Drives the default sort and the row tint.
    public var severity: Int {
        AlertSeverity.rank(type)
    }

    public init(
        type: AlertType,
        nodeNum: Int64,
        nodeName: String,
        detail: String,
        state: AlertState,
        firedAt: Instant,
        cooldownRemaining: Double? = nil,
        snoozeRemaining: Double? = nil
    ) {
        self.type = type
        self.nodeNum = nodeNum
        self.nodeName = nodeName
        self.detail = detail
        self.state = state
        self.firedAt = firedAt
        self.cooldownRemaining = cooldownRemaining
        self.snoozeRemaining = snoozeRemaining
    }
}

extension AlertConsoleItem {
    /// The state-machine key for this item (module-internal; used by the console VM).
    var engineKey: AlertKey {
        AlertKey(type: type, nodeNum: UInt32(truncatingIfNeeded: nodeNum))
    }
}
