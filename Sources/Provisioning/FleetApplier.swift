// FleetApplier — safe rolling fleet rollout (SPEC §2.7). Applies a template to the
// fleet ONE NODE AT A TIME: each node is rendered → diffed → applied → read-back
// verified before advancing. A failed verification halts the rollout (by default)
// rather than destabilising the whole network. Pure orchestration over per-node
// AdminChannels; the real transport is the effect adapter (HIL).

public enum NodeRolloutStatus: Sendable, Equatable {
    /// Applied and read-back verified.
    case verified
    /// Already matched the template (idempotent no-op).
    case noChange
    /// Plan/apply/verify failed; the rollout halts here unless told to continue.
    case failed(String)

    public var isSuccess: Bool {
        if case .failed = self { false } else { true }
    }
}

public struct NodeRolloutOutcome: Sendable, Equatable {
    public let nodeNum: Int64
    public let status: NodeRolloutStatus

    public init(nodeNum: Int64, status: NodeRolloutStatus) {
        self.nodeNum = nodeNum
        self.status = status
    }
}

public struct FleetMember: Sendable, Equatable {
    public let nodeNum: Int64
    public let context: NamingContext

    public init(nodeNum: Int64, context: NamingContext) {
        self.nodeNum = nodeNum
        self.context = context
    }
}

public struct FleetRolloutResult: Sendable, Equatable {
    public let outcomes: [NodeRolloutOutcome]

    public init(outcomes: [NodeRolloutOutcome]) {
        self.outcomes = outcomes
    }

    public var allSucceeded: Bool {
        outcomes.allSatisfy(\.status.isSuccess)
    }

    public var verifiedCount: Int {
        outcomes.count { $0.status == .verified }
    }
}

public struct FleetApplier: Sendable {
    private let channelFor: @Sendable (Int64) -> any AdminChannel

    public init(channelFor: @escaping @Sendable (Int64) -> any AdminChannel) {
        self.channelFor = channelFor
    }

    /// Roll `template` out across `members` sequentially, verifying each node took
    /// the change before moving on. Halts on the first failure when `haltOnFailure`.
    ///
    /// Cooperatively cancellable: an aborting caller cancels the surrounding task,
    /// and we check `Task.isCancelled` before each node's apply and before each
    /// progress callback. So an abort during node N applies leaves node N+1 untouched
    /// and fires no post-abort progress — the UI never mutates a row after the stop.
    @discardableResult
    public func rollOut(
        template: NodeTemplate,
        to members: [FleetMember],
        haltOnFailure: Bool = true,
        onProgress: @Sendable (NodeRolloutOutcome) async -> Void = { _ in }
    ) async -> FleetRolloutResult {
        var outcomes: [NodeRolloutOutcome] = []
        for member in members {
            // Stop before starting the next node's apply if we've been aborted.
            if Task.isCancelled { break }
            let outcome = await apply(template: template, to: member)
            outcomes.append(outcome)
            // Don't report (or mutate the UI for) a node finished after an abort.
            if Task.isCancelled { break }
            await onProgress(outcome)
            if case .failed = outcome.status, haltOnFailure { break }
        }
        return FleetRolloutResult(outcomes: outcomes)
    }

    private func apply(template: NodeTemplate, to member: FleetMember) async -> NodeRolloutOutcome {
        let applier = AdminApplier(channel: channelFor(member.nodeNum))
        do {
            let plan = try await applier.plan(template: template, context: member.context)
            if plan.isNoOp { return NodeRolloutOutcome(nodeNum: member.nodeNum, status: .noChange) }
            try await applier.apply(plan, template: template, context: member.context)
            return NodeRolloutOutcome(nodeNum: member.nodeNum, status: .verified)
        } catch {
            return NodeRolloutOutcome(nodeNum: member.nodeNum, status: .failed("\(error)"))
        }
    }
}
