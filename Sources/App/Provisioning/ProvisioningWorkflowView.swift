// ProvisioningWorkflowView — the guided single-node provisioning UI (SPEC §2.7).
// Walks the operator through the flow driven by `ProvisioningWorkflowViewModel`:
// define the template → target a node → preview the diff (with a reboot warning) →
// CONFIRM → apply → see the verification + reboot-needed result.
//
// Built with bespoke views (no stock controls / ScrollView) so it renders
// deterministically under the headless ImageRenderer snapshot gate, matching the
// look of the fleet-rollout views it sits beside. The confirm gate is visually
// distinct: nothing is applied until the operator presses the explicit Confirm.

import Provisioning
import SwiftUI

public struct ProvisioningWorkflowView: View {
    @Bindable private var viewModel: ProvisioningWorkflowViewModel

    public init(viewModel: ProvisioningWorkflowViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            stepIndicator
            content
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.03, green: 0.04, blue: 0.10))
        .task { await viewModel.load() }
    }

    // MARK: Header + step indicator

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Provision a node").font(.title.bold()).foregroundStyle(.white)
            Text("Render a template, preview the change, then confirm before anything is applied.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    private var stepIndicator: some View {
        HStack(spacing: 8) {
            ForEach(ProvisioningWorkflowViewModel.Step.allCases, id: \.self) { step in
                StepChip(
                    title: step.title,
                    state: state(for: step)
                )
            }
        }
    }

    private func state(for step: ProvisioningWorkflowViewModel.Step) -> StepChip.State {
        if step == viewModel.step {
            .current
        } else if step.rawValue < viewModel.step.rawValue {
            .done
        } else {
            .upcoming
        }
    }

    // MARK: Per-step content

    @ViewBuilder private var content: some View {
        switch viewModel.step {
        case .template: templateStep
        case .target: targetStep
        case .preview: previewStep
        case .confirm: confirmStep
        case .applying: applyingStep
        case .result: resultStep
        }
    }

    // MARK: Template step

    private var templateStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Template")
            field("Name", text: $viewModel.draft.name)
            field("Region (always set — legal)", text: $viewModel.draft.region)
            field("Role", text: $viewModel.draft.role)
            field("Short-name DSL", text: $viewModel.draft.shortNameDSL)
            field("Long-name DSL", text: $viewModel.draft.longNameDSL)
            field("Position precision (bits)", text: $viewModel.draft.positionPrecision)
            ProvisioningButton(
                title: "Choose target",
                systemImage: "arrow.right",
                tint: .cyan,
                enabled: viewModel.canAdvance
            ) {
                viewModel.goToTarget()
            }
        }
    }

    // MARK: Target step

    private var targetStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Target node")
            if viewModel.candidates.isEmpty {
                Text("No nodes available to provision.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            VStack(spacing: 8) {
                ForEach(viewModel.candidates) { candidate in
                    TargetRow(
                        candidate: candidate,
                        selected: viewModel.selectedTarget?.nodeNum == candidate.nodeNum
                    ) { viewModel.selectTarget(candidate) }
                }
            }
            HStack(spacing: 10) {
                ProvisioningButton(title: "Back", systemImage: "arrow.left", tint: .gray, enabled: true) {
                    viewModel.back()
                }
                ProvisioningButton(
                    title: "Preview diff",
                    systemImage: "eye",
                    tint: .cyan,
                    enabled: viewModel.canAdvance
                ) {
                    Task { await viewModel.preview() }
                }
            }
        }
    }

    // MARK: Preview step

    private var previewStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Preview")
            if let error = viewModel.lastError {
                ProvisioningErrorBanner(message: error)
            } else if let plan = viewModel.plan {
                if plan.isNoOp {
                    InfoBanner(
                        icon: "equal.circle.fill",
                        tint: .green,
                        title: "Already configured",
                        message: "The node already matches the template — nothing to apply."
                    )
                } else {
                    DiffList(changes: plan.changes)
                    if viewModel.reboot.requiresReboot {
                        RebootWarning(fields: viewModel.reboot.rebootingFields)
                    }
                }
            }
            HStack(spacing: 10) {
                ProvisioningButton(title: "Back", systemImage: "arrow.left", tint: .gray, enabled: true) {
                    viewModel.back()
                }
                ProvisioningButton(
                    title: "Review & confirm",
                    systemImage: "arrow.right",
                    tint: .orange,
                    enabled: viewModel.canAdvance
                ) {
                    viewModel.reviewForConfirmation()
                }
            }
        }
    }

    // MARK: Confirm step (the gate)

    private var confirmStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Confirm")
            InfoBanner(
                icon: "exclamationmark.shield.fill",
                tint: .orange,
                title: "Apply \(viewModel.plan?.changes.count ?? 0) change(s) to “\(targetName)”?",
                message: viewModel.reboot.requiresReboot
                    ? "This will reboot the node (\(viewModel.reboot.rebootingFields.joined(separator: ", ")))."
                    : "These changes apply live; no reboot needed."
            )
            if let plan = viewModel.plan { DiffList(changes: plan.changes) }
            HStack(spacing: 10) {
                ProvisioningButton(title: "Back", systemImage: "arrow.left", tint: .gray, enabled: true) {
                    viewModel.back()
                }
                ProvisioningButton(
                    title: "Confirm & apply",
                    systemImage: "checkmark.seal.fill",
                    tint: .green,
                    enabled: true
                ) {
                    Task { await viewModel.confirmAndApply() }
                }
            }
        }
    }

    // MARK: Applying / result

    private var applyingStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Applying")
            InfoBanner(
                icon: "arrow.triangle.2.circlepath",
                tint: .cyan,
                title: "Applying to “\(targetName)”…",
                message: "Sending admin messages and reading the config back to verify."
            )
        }
    }

    private var resultStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Result")
            resultBanner
            ProvisioningButton(title: "Provision another", systemImage: "plus", tint: .cyan, enabled: true) {
                viewModel.provisionAnother()
            }
        }
    }

    @ViewBuilder private var resultBanner: some View {
        switch viewModel.outcome {
        case let .applied(rebooting):
            InfoBanner(
                icon: "checkmark.circle.fill",
                tint: .green,
                title: "Applied & verified",
                message: rebooting
                    ? "The node took the change and is rebooting to finish."
                    : "The node took the change; read-back verified."
            )
        case .noChange:
            InfoBanner(
                icon: "equal.circle.fill", tint: .green,
                title: "No change", message: "The node already matched the template."
            )
        case let .verificationFailed(remaining):
            VStack(alignment: .leading, spacing: 10) {
                InfoBanner(
                    icon: "xmark.octagon.fill", tint: .red,
                    title: "Verification failed",
                    message: "Read-back still differs — the node didn't take the change."
                )
                DiffList(changes: remaining)
            }
        case let .error(message):
            ProvisioningErrorBanner(message: message)
        case nil:
            EmptyView()
        }
    }

    // MARK: Helpers

    private var targetName: String {
        viewModel.selectedTarget?.name ?? "node"
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 15, weight: .bold)).foregroundStyle(.white)
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        ProvisioningField(label: label, text: text)
    }
}
