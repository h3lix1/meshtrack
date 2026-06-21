// AlertEngine — the alert state machine (SPEC §2.6).
//
// Wraps the pure RuleEvaluator conditions into alert lifecycle: firing →
// acknowledged → resolved, with cooldown (rate-limit re-firing), snooze, and ack.
// Storm suppression: conditions reconciled as `historical` (backfilled on
// startup/reconnect) update state silently — they never emit live events, and a
// never-announced alert never emits a spurious `resolved`. Pure value type; the
// owning collector actor holds one instance.

import Domain

/// Identity of an alert: one per (type, node).
public struct AlertKey: Hashable, Sendable {
    public let type: AlertType
    public let nodeNum: UInt32

    public init(type: AlertType, nodeNum: UInt32) {
        self.type = type
        self.nodeNum = nodeNum
    }
}

public struct Alert: Sendable, Equatable {
    public let type: AlertType
    public let nodeNum: UInt32
    public var state: AlertState
    public var firedAt: Instant
    public var resolvedAt: Instant?
    public var ackedAt: Instant?
    public var snoozedUntil: Instant?
    public var cooldownSeconds: Double
    /// Whether a `fired` event was actually delivered (false for storm-suppressed).
    public var wasAnnounced: Bool

    public var key: AlertKey {
        AlertKey(type: type, nodeNum: nodeNum)
    }
}

/// An event to deliver to the notifier.
public enum AlertEvent: Sendable, Equatable {
    case fired(Alert)
    case resolved(Alert)
}

public struct AlertEngine: Sendable {
    private var active: [AlertKey: Alert] = [:]

    public init() {}

    /// All currently-tracked alerts (firing / acknowledged / resolved).
    public var alerts: [Alert] {
        Array(active.values)
    }

    public func alert(type: AlertType, nodeNum: UInt32) -> Alert? {
        active[AlertKey(type: type, nodeNum: nodeNum)]
    }

    /// Reconcile current conditions against tracked alerts at `now`, returning the
    /// events to deliver. `historical` suppresses all live emission (storm control).
    @discardableResult
    public mutating func reconcile(
        _ conditions: [AlertCondition],
        now: Instant,
        historical: Bool = false
    ) -> [AlertEvent] {
        var events: [AlertEvent] = []
        let present = Set(conditions.map { AlertKey(type: $0.type, nodeNum: $0.nodeNum) })

        for condition in conditions {
            if let event = fire(condition, now: now, historical: historical) { events.append(event) }
        }

        // Conditions that no longer hold → resolve (snapshot first to mutate safely).
        let toResolve = active.filter { !present.contains($0.key) && $0.value.state != .resolved }
        for (key, alert) in toResolve {
            var resolved = alert
            resolved.state = .resolved
            resolved.resolvedAt = now
            active[key] = resolved
            if alert.wasAnnounced, !historical { events.append(.resolved(resolved)) }
        }
        return events
    }

    public mutating func acknowledge(type: AlertType, nodeNum: UInt32, at now: Instant) {
        let key = AlertKey(type: type, nodeNum: nodeNum)
        guard var alert = active[key], alert.state == .firing else { return }
        alert.state = .acknowledged
        alert.ackedAt = now
        active[key] = alert
    }

    public mutating func snooze(type: AlertType, nodeNum: UInt32, until: Instant) {
        let key = AlertKey(type: type, nodeNum: nodeNum)
        guard var alert = active[key] else { return }
        alert.snoozedUntil = until
        active[key] = alert
    }

    // MARK: - Firing

    private mutating func fire(_ condition: AlertCondition, now: Instant, historical: Bool) -> AlertEvent? {
        let key = AlertKey(type: condition.type, nodeNum: condition.nodeNum)
        guard let existing = active[key] else {
            return start(condition, key: key, now: now, historical: historical, snoozedUntil: nil)
        }
        // Already firing/acknowledged → still active, no new event.
        guard existing.state == .resolved else { return nil }
        // Re-fire only after the cooldown since it resolved.
        let since = now.secondsSince(existing.resolvedAt ?? existing.firedAt)
        guard since >= existing.cooldownSeconds else { return nil }
        return start(
            condition,
            key: key,
            now: now,
            historical: historical,
            snoozedUntil: existing.snoozedUntil
        )
    }

    private mutating func start(
        _ condition: AlertCondition,
        key: AlertKey,
        now: Instant,
        historical: Bool,
        snoozedUntil: Instant?
    ) -> AlertEvent? {
        var alert = Alert(
            type: condition.type, nodeNum: condition.nodeNum, state: .firing, firedAt: now,
            resolvedAt: nil, ackedAt: nil, snoozedUntil: snoozedUntil,
            cooldownSeconds: condition.cooldownSeconds, wasAnnounced: false
        )
        let announce = !historical && !isSnoozed(alert, now: now)
        alert.wasAnnounced = announce
        active[key] = alert
        return announce ? .fired(alert) : nil
    }

    private func isSnoozed(_ alert: Alert, now: Instant) -> Bool {
        if let until = alert.snoozedUntil { return now < until }
        return false
    }
}
