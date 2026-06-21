// AdminApplier — the apply flow (SPEC §2.7): render → diff → (confirm) → apply →
// read-back → verify idempotent. The flow is pure orchestration over an
// `AdminChannel` port; the real adapter builds AdminMessage/ConfigModule
// protobufs and carries them over local or remote admin (PKI admin key or legacy
// admin channel) — that transport is validated on hardware (HIL), not in CI.

/// Port: reads and writes a node's config via admin messages. Adapters: local
/// (USB/BLE), remote PKI-admin, remote legacy-admin-channel.
public protocol AdminChannel: Sendable {
    func currentConfig() async throws -> [String: String]
    func apply(_ changes: [ConfigChange]) async throws
}

/// The dry-run result: the changes an apply would make. Empty = idempotent no-op.
public struct ApplyPlan: Sendable, Equatable {
    public let changes: [ConfigChange]
    public var isNoOp: Bool {
        changes.isEmpty
    }

    public init(changes: [ConfigChange]) {
        self.changes = changes
    }
}

public enum ApplyError: Error, Equatable, Sendable {
    /// Read-back after apply still showed differences (the node didn't take it).
    case verificationFailed(remaining: [ConfigChange])
}

public struct AdminApplier: Sendable {
    private let channel: any AdminChannel

    public init(channel: any AdminChannel) {
        self.channel = channel
    }

    /// Dry-run: render the template and diff it against the live node. No mutation.
    public func plan(template: NodeTemplate, context: NamingContext) async throws -> ApplyPlan {
        try await computePlan(template: template, context: context)
    }

    /// Apply a (confirmed) plan, then read back and verify the node now matches.
    /// A no-op plan applies nothing. Throws `ApplyError.verificationFailed` if the
    /// read-back still differs.
    @discardableResult
    public func apply(
        _ plan: ApplyPlan,
        template: NodeTemplate,
        context: NamingContext
    ) async throws -> ApplyPlan {
        guard !plan.isNoOp else { return plan }
        try await channel.apply(plan.changes)
        let readBack = try await computePlan(template: template, context: context)
        guard readBack.isNoOp else { throw ApplyError.verificationFailed(remaining: readBack.changes) }
        return plan
    }

    private func computePlan(template: NodeTemplate, context: NamingContext) async throws -> ApplyPlan {
        let desired = try template.desiredConfig(for: context)
        let current = try await channel.currentConfig()
        return ApplyPlan(changes: ConfigDiff.changes(desired: desired, current: current))
    }
}
