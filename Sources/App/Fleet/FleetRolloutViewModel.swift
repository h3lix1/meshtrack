// FleetRolloutViewModel — the live driver for a safe rolling fleet rollout
// (SPEC §2.7, G7). It wires the proven `FleetApplier` engine to a testable
// presentation layer: pick a `NodeTemplate` + members, preview the per-node
// `ConfigDiff` (dry-run, no mutation), then roll the template out ONE NODE AT A
// TIME — each node is applied and read-back verified before the next is touched.
// The first failure HALTS the rollout (by default) so a bad change can never
// destabilise the fleet.
//
// `@MainActor @Observable`: the per-node status, overall progress, and the abort
// control are all observable so the SwiftUI view mirrors the engine live. The
// engine's `onProgress` callback runs off the main actor; we hop back here to
// mutate state. The whole flow is unit-tested by injecting a `FleetApplier` built
// over a fake `AdminChannel`.

import Domain
import Foundation
import Observation
import Provisioning

@Observable
@MainActor
public final class FleetRolloutViewModel {
    /// The live status of one node in the rollout, mirroring `FleetApplier`'s
    /// `NodeRolloutStatus` plus the in-flight states the engine doesn't model
    /// (`pending`/`applying`) and the field the row shows.
    public enum NodeStatus: Sendable, Equatable {
        /// Not yet reached by the sequential rollout.
        case pending
        /// Currently being applied + verified (the engine is on this node).
        case applying
        /// Applied and read-back verified.
        case verified
        /// Already matched the template (idempotent no-op).
        case noChange
        /// Plan/apply/verify failed; the rollout halts here (unless told not to).
        case failed(String)

        /// A finished node counts toward "done"; `pending`/`applying` do not.
        public var isTerminal: Bool {
            switch self {
            case .pending, .applying: false
            case .verified, .noChange, .failed: true
            }
        }

        /// A terminal-and-successful node (verified or an idempotent no-op).
        public var isSuccess: Bool {
            switch self {
            case .verified, .noChange: true
            case .pending, .applying, .failed: false
            }
        }
    }

    /// One row of the rollout: a fleet member, its live status, and its previewed
    /// per-node diff (the changes the rollout would make to it).
    public struct Row: Identifiable, Sendable, Equatable {
        public let member: FleetMember
        public let name: String
        public internal(set) var status: NodeStatus
        public internal(set) var changes: [ConfigChange]

        public var id: Int64 {
            member.nodeNum
        }

        public init(
            member: FleetMember,
            name: String,
            status: NodeStatus = .pending,
            changes: [ConfigChange] = []
        ) {
            self.member = member
            self.name = name
            self.status = status
            self.changes = changes
        }
    }

    /// Where the rollout is in its lifecycle.
    public enum Phase: Sendable, Equatable {
        case idle
        case previewing
        case rolling
        /// Completed (every member terminal, or halted at a failure).
        case finished
        /// Aborted by the operator before completion.
        case aborted
    }

    public let template: NodeTemplate
    /// Halt at the first failed node (the safe default). When `false`, a failure is
    /// recorded but the rollout continues to the next node.
    public var haltOnFailure: Bool
    public private(set) var rows: [Row]
    public private(set) var phase: Phase = .idle

    /// Resolves a node's admin channel. Used to build both the rollout engine and
    /// the per-node dry-run previews. Injected so tests supply a fake `AdminChannel`.
    @ObservationIgnored private let channelFor: @Sendable (Int64) -> any AdminChannel
    @ObservationIgnored private let applier: FleetApplier
    @ObservationIgnored private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - channelFor: resolves a node's `AdminChannel`. Tests pass a fake; the live
    ///     app passes the real local/remote admin transport. Drives both the engine
    ///     and the dry-run previews.
    ///   - template: the template to roll out across the fleet.
    ///   - members: the selected nodes, in rollout order.
    ///   - names: optional display name per node-num (falls back to the hex id).
    ///   - haltOnFailure: stop at the first failure (default `true`, the safe path).
    public init(
        channelFor: @escaping @Sendable (Int64) -> any AdminChannel,
        template: NodeTemplate,
        members: [FleetMember],
        names: [Int64: String] = [:],
        haltOnFailure: Bool = true
    ) {
        self.channelFor = channelFor
        applier = FleetApplier(channelFor: channelFor)
        self.template = template
        self.haltOnFailure = haltOnFailure
        rows = members.map { member in
            Row(member: member, name: names[member.nodeNum] ?? Self.hexID(member.nodeNum))
        }
    }

    // MARK: Derived progress

    public var total: Int {
        rows.count
    }

    /// Nodes verified or no-op'd so far (the "x/y verified" headline).
    public var verifiedCount: Int {
        rows.count { $0.status.isSuccess }
    }

    /// Whether any node failed (the rollout did not fully succeed).
    public var hasFailure: Bool {
        rows.contains { if case .failed = $0.status { true } else { false } }
    }

    /// 0…1 share of the fleet that reached a terminal state (drives the progress bar).
    public var progress: Double {
        guard !rows.isEmpty else { return 0 }
        let done = rows.count { $0.status.isTerminal }
        return Double(done) / Double(rows.count)
    }

    /// Whether a rollout is currently in flight (enables the abort control).
    public var isRolling: Bool {
        phase == .rolling
    }

    // MARK: Preview (dry-run)

    /// Dry-run every member: render the template, diff it against the live node, and
    /// surface the per-node changes. No mutation. Failed previews mark the row
    /// `failed` so the operator sees a bad node before committing to a rollout.
    public func preview() async {
        phase = .previewing
        for index in rows.indices {
            let member = rows[index].member
            let perNode = AdminApplier(channel: channelFor(member.nodeNum))
            do {
                let plan = try await perNode.plan(template: template, context: member.context)
                rows[index].changes = plan.changes
                rows[index].status = plan.isNoOp ? .noChange : .pending
            } catch {
                rows[index].changes = []
                rows[index].status = .failed(Self.describe(error))
            }
        }
        phase = .idle
    }

    // MARK: Rollout

    /// Roll the template out across the fleet, verifying each node before the next
    /// and (by default) halting at the first failure. Live per-node status updates
    /// drive the view. Idempotent no-ops are reported without mutating the node.
    public func startRollout() {
        guard !isRolling else { return }
        resetRunStates()
        phase = .rolling
        // The engine only reports a node when it *finishes*. To mirror "the engine
        // is on node N now", we light the first node `applying` up front, then on
        // each completion advance the highlight to the next pending node.
        markFirstPendingApplying()
        task = Task { [self] in await run() }
    }

    /// Drive the engine to completion, awaiting each finished node so the live
    /// status keeps in step. Bounded: `task` is released on completion (or abort),
    /// so the strong `self` capture is not a lasting cycle.
    private func run() async {
        let members = rows.map(\.member)
        await applier.rollOut(
            template: template,
            to: members,
            haltOnFailure: haltOnFailure,
            onProgress: { [weak self] outcome in
                await self?.advance(after: outcome)
            }
        )
        finish()
    }

    /// Abort an in-flight rollout. Nodes already verified stay verified; the node in
    /// flight and any not-yet-reached node are left as they are (no new applies).
    public func abort() {
        guard isRolling else { return }
        task?.cancel()
        task = nil
        for index in rows.indices where rows[index].status == .applying {
            rows[index].status = .pending
        }
        phase = .aborted
    }

    // MARK: Live status transitions (called from the engine's callbacks)

    /// Light the first not-yet-run node as `applying` (the engine starts there).
    private func markFirstPendingApplying() {
        guard let index = rows.firstIndex(where: { $0.status == .pending }) else { return }
        rows[index].status = .applying
    }

    /// Record a finished node's real outcome, then — unless it halted the rollout —
    /// light the next pending node as `applying`.
    private func advance(after outcome: NodeRolloutOutcome) {
        // Ignore any callback that lands after an abort/finish: only a rollout in
        // flight may mutate rows, so a stale outcome can't resurrect an aborted run.
        guard phase == .rolling else { return }
        guard let index = rows.firstIndex(where: { $0.member.nodeNum == outcome.nodeNum }) else { return }
        let status = Self.present(outcome.status)
        rows[index].status = status
        let halts = haltOnFailure && !status.isSuccess
        guard !halts else { return }
        markFirstPendingApplying()
    }

    private func finish() {
        guard phase == .rolling else { return } // aborted runs keep their `.aborted` phase
        task = nil
        phase = .finished
    }

    // MARK: Helpers

    /// Clear transient run states before a (re)start: keep `noChange` rows (they are
    /// already correct) but reset everything else to `pending`.
    private func resetRunStates() {
        for index in rows.indices where rows[index].status != .noChange {
            rows[index].status = .pending
        }
    }

    private static func present(_ status: NodeRolloutStatus) -> NodeStatus {
        switch status {
        case .verified: .verified
        case .noChange: .noChange
        case let .failed(reason): .failed(reason)
        }
    }

    private static func describe(_ error: any Error) -> String {
        "\(error)"
    }

    nonisolated static func hexID(_ nodeNum: Int64) -> String {
        NodeID.hex(UInt32(truncatingIfNeeded: nodeNum))
    }
}
