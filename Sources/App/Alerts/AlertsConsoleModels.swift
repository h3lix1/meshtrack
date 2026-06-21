// AlertsConsoleModels — small, pure presentation types for the alerts console
// (G5). Split out of AlertsConsoleViewModel.swift to keep each file focused.

import RuleEngine

/// Severity ranking for alert types — ownership/safety-critical kinds outrank
/// informational ones. Stable, pure; unit-tested independently.
public enum AlertSeverity {
    public static func rank(_ type: AlertType) -> Int {
        switch type {
        case .voltageBelow: 5
        case .batteryBelow: 4
        case .geofenceExit, .moved: 3
        case .stale: 2
        case .channelUtilHigh: 1
        case .newNodeSeen, .backOnline, .returned: 0
        }
    }
}

/// How the console sorts within each state group.
public enum AlertSort: Sendable, Equatable, CaseIterable {
    /// Most-urgent first, ties broken by most-recent.
    case severity
    /// Most-recent first.
    case recency
}

/// A node whose ownership classification suppresses ownership-sensitive alerts
/// (ADR 0008) — surfaced so users understand why a low-battery stranger is quiet.
public struct SuppressedNode: Sendable, Equatable, Identifiable {
    public var id: Int64 {
        nodeNum
    }

    public let nodeNum: Int64
    public let nodeName: String
    /// Why it's suppressed in plain language (e.g. "unmanaged — battery/stale
    /// alerts off").
    public let reason: String

    public init(nodeNum: Int64, nodeName: String, reason: String) {
        self.nodeNum = nodeNum
        self.nodeName = nodeName
        self.reason = reason
    }
}
