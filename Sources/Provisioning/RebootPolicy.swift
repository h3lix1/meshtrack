// RebootPolicy — which config changes require the node to reboot (SPEC §2.7:
// "Some changes require a reboot; surface that").
//
// Pure classification: given an `ApplyPlan`'s changes, report whether applying
// them will force a reboot and which fields drive it, so the workflow can warn the
// operator BEFORE they confirm. Region and role are device/radio-level settings
// that the firmware applies on reboot; owner names and position precision take
// effect live. The list is intentionally conservative — when in doubt, surface
// the reboot rather than surprise the operator.

import Foundation

/// Whether and why an apply will reboot the node.
public struct RebootAssessment: Sendable, Equatable {
    /// True if any change in the plan requires a reboot to take effect.
    public let requiresReboot: Bool
    /// The fields (by name) that force the reboot, in stable order.
    public let rebootingFields: [String]

    public init(requiresReboot: Bool, rebootingFields: [String]) {
        self.requiresReboot = requiresReboot
        self.rebootingFields = rebootingFields
    }
}

public enum RebootPolicy {
    /// Config fields whose change forces a reboot. Region and role are radio /
    /// device-level and only take effect on restart; names and position precision
    /// apply live.
    static let rebootingFields: Set<String> = [
        AdminConfigField.region.rawValue,
        AdminConfigField.role.rawValue
    ]

    /// Assess whether the given changes will reboot the node.
    public static func assess(_ changes: [ConfigChange]) -> RebootAssessment {
        let driving = changes
            .map(\.field)
            .filter(rebootingFields.contains)
            .sorted()
        return RebootAssessment(requiresReboot: !driving.isEmpty, rebootingFields: driving)
    }

    /// Convenience over an `ApplyPlan`.
    public static func assess(_ plan: ApplyPlan) -> RebootAssessment {
        assess(plan.changes)
    }
}
