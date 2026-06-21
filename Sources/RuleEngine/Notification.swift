// Notification delivery seam (SPEC §2.6).
//
// The `Notifier` port is the boundary; adapters (macOS Notification Center,
// ntfy/webhook, console) live in the Delivery module. The formatting of an
// AlertEvent into a human-readable notification is pure and tested here.

import Domain

/// A formatted, delivery-ready notification.
public struct AlertNotification: Sendable, Equatable {
    public let title: String
    public let body: String
    public let alertType: AlertType
    public let nodeNum: UInt32
    public let isResolution: Bool

    public init(title: String, body: String, alertType: AlertType, nodeNum: UInt32, isResolution: Bool) {
        self.title = title
        self.body = body
        self.alertType = alertType
        self.nodeNum = nodeNum
        self.isResolution = isResolution
    }
}

/// Port: delivers a notification. Adapters: UNNotifier (default), WebhookNotifier
/// (ntfy/webhook), ConsoleNotifier. Acks round-trip back into the state machine.
public protocol Notifier: Sendable {
    func send(_ notification: AlertNotification) async
}

public enum NotificationFormatter {
    public static func notification(for event: AlertEvent) -> AlertNotification {
        switch event {
        case let .fired(alert):
            AlertNotification(
                title: title(for: alert.type),
                body: "!\(hex(alert.nodeNum)): \(alert.detail)",
                alertType: alert.type,
                nodeNum: alert.nodeNum,
                isResolution: false
            )
        case let .resolved(alert):
            AlertNotification(
                title: "Resolved — \(title(for: alert.type))",
                body: "!\(hex(alert.nodeNum)) recovered",
                alertType: alert.type,
                nodeNum: alert.nodeNum,
                isResolution: true
            )
        }
    }

    private static func title(for type: AlertType) -> String {
        switch type {
        case .stale: "Node went silent"
        case .batteryBelow: "Battery low"
        case .voltageBelow: "Voltage low"
        case .moved: "Node moved"
        case .returned: "Node returned"
        case .geofenceExit: "Geofence exit"
        case .channelUtilHigh: "Channel utilization high"
        case .newNodeSeen: "New node seen"
        case .backOnline: "Node back online"
        }
    }

    /// Lowercase 8-digit hex node id, Foundation-free.
    private static func hex(_ value: UInt32) -> String {
        let digits = Array("0123456789abcdef")
        var result = ""
        for shift in stride(from: 28, through: 0, by: -4) {
            result.append(digits[Int((value >> UInt32(shift)) & 0xF)])
        }
        return result
    }
}

/// Formats and delivers alert events through a `Notifier`.
public struct NotificationDispatcher: Sendable {
    private let notifier: any Notifier

    public init(notifier: any Notifier) {
        self.notifier = notifier
    }

    public func dispatch(_ events: [AlertEvent]) async {
        for event in events {
            await notifier.send(NotificationFormatter.notification(for: event))
        }
    }
}
