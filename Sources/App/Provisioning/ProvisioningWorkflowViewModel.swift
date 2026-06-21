// ProvisioningWorkflowViewModel — the guided single-node provisioning flow
// (SPEC §2.7). The single-node sibling of the fleet-config engine: instead of
// rolling a template across many nodes, it walks an operator through provisioning
// ONE node, step by step, with an explicit confirm gate before anything is applied.
//
// Steps (a strict, forward lifecycle):
//   template → target → preview → confirm → applying → result
//
// At `preview` it renders the chosen template against the target, diffs it against
// the live node (dry-run, no mutation), and assesses whether the apply will reboot
// the node. NOTHING is applied until the operator explicitly `confirmAndApply()`s —
// the confirm gate is the heart of the safety story. After apply it read-back
// verifies (via `AdminApplier`) and surfaces success / verification-failure /
// reboot-needed.
//
// `@MainActor @Observable`, driven entirely over the `AdminChannel` port so a test
// supplies a fake channel (no store, no radio). The live app injects the real
// `MeshAdminChannel` (local USB/BLE or remote PKI/legacy admin) — the HIL effect.

import Foundation
import Observation
import Provisioning

@Observable
@MainActor
public final class ProvisioningWorkflowViewModel {
    /// Where the operator is in the guided flow. Strictly forward; `reset()` returns
    /// to `target` to provision another node, `back()` steps one stage back where
    /// it's safe (never out of `applying`).
    public enum Step: Int, Sendable, Equatable, CaseIterable {
        case template
        case target
        case preview
        case confirm
        case applying
        case result

        public var title: String {
            switch self {
            case .template: "Template"
            case .target: "Target node"
            case .preview: "Preview"
            case .confirm: "Confirm"
            case .applying: "Applying"
            case .result: "Result"
            }
        }
    }

    /// The terminal outcome of an apply.
    public enum Outcome: Sendable, Equatable {
        /// Applied and read-back verified. `rebooting` is true if the node will reboot.
        case applied(rebooting: Bool)
        /// The node was already configured — nothing to apply (idempotent no-op).
        case noChange
        /// Read-back after apply still differed (the node didn't take it).
        case verificationFailed(remaining: [ConfigChange])
        /// The apply or read-back errored (transport fault, bad template, …).
        case error(String)

        public var isSuccess: Bool {
            switch self {
            case .applied, .noChange: true
            case .verificationFailed, .error: false
            }
        }
    }

    /// A node the operator can target. Built from the store in the live app; tests
    /// supply them directly.
    public struct TargetCandidate: Identifiable, Sendable, Equatable {
        public let nodeNum: Int64
        public let name: String
        public let hexID: String
        public let shortName: String?
        public let longName: String?
        public let role: String?
        /// A freshly-discovered, not-yet-recorded node (e.g. just seen on serial/BLE).
        public let isNewlyDiscovered: Bool

        public var id: Int64 {
            nodeNum
        }

        public init(
            nodeNum: Int64,
            name: String,
            hexID: String,
            shortName: String? = nil,
            longName: String? = nil,
            role: String? = nil,
            isNewlyDiscovered: Bool = false
        ) {
            self.nodeNum = nodeNum
            self.name = name
            self.hexID = hexID
            self.shortName = shortName
            self.longName = longName
            self.role = role
            self.isNewlyDiscovered = isNewlyDiscovered
        }
    }

    // MARK: Observable state

    public private(set) var step: Step = .template
    public var draft: TemplateDraft
    public private(set) var candidates: [TargetCandidate] = []
    public private(set) var selectedTarget: TargetCandidate?
    /// How a remote node is authorised (local for a directly-attached radio).
    public var authority: AdminAuthority = .local
    /// The dry-run plan produced at `preview` (the changes the apply would make).
    public private(set) var plan: ApplyPlan?
    /// Whether the previewed apply will reboot the node (surfaced before confirm).
    public private(set) var reboot: RebootAssessment = .init(requiresReboot: false, rebootingFields: [])
    public private(set) var outcome: Outcome?
    public private(set) var lastError: String?

    // MARK: Dependencies (ports)

    /// Resolves an `AdminChannel` for a target. Tests pass a fake; the live app
    /// builds a `MeshAdminChannel` over the real transport for the chosen authority.
    @ObservationIgnored private let channelFor: @Sendable (AdminTarget) -> any AdminChannel
    /// Supplies the targetable nodes (store-backed in the app; injected in tests).
    @ObservationIgnored private let loadCandidates: @Sendable () async -> [TargetCandidate]

    public init(
        draft: TemplateDraft = TemplateDraft(),
        channelFor: @escaping @Sendable (AdminTarget) -> any AdminChannel,
        loadCandidates: @escaping @Sendable () async -> [TargetCandidate] = { [] }
    ) {
        self.draft = draft
        self.channelFor = channelFor
        self.loadCandidates = loadCandidates
    }

    // MARK: Derived

    /// The `NodeTemplate` described by the current draft (what the apply renders).
    public var template: NodeTemplate {
        draft.template
    }

    /// The naming context for the selected target (drives the DSL render).
    public var targetContext: NamingContext? {
        selectedTarget.map { target in
            NamingContext(
                id: target.hexID,
                shortName: target.shortName,
                longName: target.longName,
                region: nil,
                role: target.role
            )
        }
    }

    /// Whether the flow can advance from the current step.
    public var canAdvance: Bool {
        switch step {
        case .template: !draft.region.isEmpty // region is always required (legal)
        case .target: selectedTarget != nil
        case .preview: plan.map { !$0.isNoOp } ?? false
        case .confirm, .applying, .result: false
        }
    }

    // MARK: Loading

    public func load() async {
        candidates = await loadCandidates()
    }

    // MARK: Step navigation

    public func selectTarget(_ candidate: TargetCandidate) {
        selectedTarget = candidate
    }

    /// Move from the template step to target selection.
    public func goToTarget() {
        guard step == .template, !draft.region.isEmpty else { return }
        step = .target
    }

    /// Step back one stage where it's safe (never out of an in-flight apply).
    public func back() {
        switch step {
        case .target: step = .template
        case .preview: step = .target
        case .confirm: step = .preview
        case .template, .applying, .result: break
        }
    }

    // MARK: Preview (dry-run)

    /// Render the template against the target, diff it against the live node, and
    /// assess the reboot impact — WITHOUT applying anything. Moves to `preview`.
    public func preview() async {
        guard let target = selectedTarget, let context = targetContext else { return }
        lastError = nil
        let admin = AdminTarget(nodeNum: target.nodeNum, authority: authority)
        let applier = AdminApplier(channel: channelFor(admin))
        do {
            let plan = try await applier.plan(template: template, context: context)
            self.plan = plan
            reboot = RebootPolicy.assess(plan)
            step = .preview
        } catch {
            plan = nil
            lastError = Self.describe(error)
            step = .preview
        }
    }

    /// Advance from a non-trivial preview to the explicit confirm gate.
    public func reviewForConfirmation() {
        guard step == .preview, let plan, !plan.isNoOp else { return }
        step = .confirm
    }

    // MARK: Apply (only past the confirm gate)

    /// Apply the previewed plan — ONLY callable from the confirm step, so a change
    /// can never be applied without the operator first confirming. Read-back
    /// verifies; the outcome (including reboot-needed) lands on `outcome`.
    public func confirmAndApply() async {
        guard step == .confirm, let target = selectedTarget,
              let context = targetContext, let plan, !plan.isNoOp
        else { return }
        step = .applying
        lastError = nil
        let admin = AdminTarget(nodeNum: target.nodeNum, authority: authority)
        let applier = AdminApplier(channel: channelFor(admin))
        do {
            try await applier.apply(plan, template: template, context: context)
            outcome = .applied(rebooting: reboot.requiresReboot)
        } catch let ApplyError.verificationFailed(remaining) {
            outcome = .verificationFailed(remaining: remaining)
        } catch {
            lastError = Self.describe(error)
            outcome = .error(Self.describe(error))
        }
        step = .result
    }

    // MARK: Reset

    /// Return to target selection to provision another node, keeping the template.
    public func provisionAnother() {
        selectedTarget = nil
        plan = nil
        outcome = nil
        lastError = nil
        reboot = RebootAssessment(requiresReboot: false, rebootingFields: [])
        step = .target
    }

    /// Full reset back to the template step.
    public func reset() {
        provisionAnother()
        step = .template
    }

    private static func describe(_ error: any Error) -> String {
        "\(error)"
    }
}
