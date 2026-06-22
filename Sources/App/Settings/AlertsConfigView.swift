// AlertsConfigView — the Alert-rules configuration screen (SPEC §2.6). A bespoke
// dark editor over `AlertsConfigViewModel`, grouped by scope (global → class →
// node): each group lists its threshold rules with a bespoke −/value/+ stepper, an
// enable switch, and a delete button; a footer edits the global default snooze.
// Control-bespoke (no stock `Stepper`) so it renders deterministically under the
// headless `ImageRenderer` snapshot gate. The lead registers it for
// `SettingsTab.alerts` at integration.

import Domain
import SwiftUI

public struct AlertsConfigView: View {
    private let viewModel: AlertsConfigViewModel

    public init(viewModel: AlertsConfigViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 18) {
                if viewModel.groups.isEmpty {
                    emptyHint
                }
                ForEach(viewModel.displayGroups) { group in
                    ScopeGroupView(group: group, viewModel: viewModel)
                }
                AddScopeBar(viewModel: viewModel)
                snoozeFooter
                if let message = viewModel.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GeneralSettingsView.canvas)
        .foregroundStyle(.white)
        // Load persisted rules + default snooze before the operator can edit/Save, so
        // opening the tab never overwrites stored values with model defaults (Finding 3).
        .task { await viewModel.load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Alert rules").font(.title.bold())
            Text("thresholds resolve node → class → global")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.bottom, 20)
    }

    /// Shown above the always-present Global group when nothing is configured yet, so
    /// the screen explains how to start rather than reading as broken.
    private var emptyHint: some View {
        Text("No rules yet — use “Add rule” to set global defaults, or “Add scope” "
            + "below to target a node class or a specific node.")
            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 2)
    }

    private var snoozeFooter: some View {
        SettingsGroup(title: "DEFAULTS") {
            StepperRow(
                label: "Default snooze",
                detail: "how long a snoozed alert stays quiet",
                value: viewModel.snoozeLabel,
                onDecrement: { Task { await viewModel.stepSnooze(by: -1) } },
                onIncrement: { Task { await viewModel.stepSnooze(by: 1) } },
                canDecrement: viewModel.defaultSnoozeSeconds >
                    AlertsConfigViewModel.snoozeRange.lowerBound,
                canIncrement: viewModel.defaultSnoozeSeconds <
                    AlertsConfigViewModel.snoozeRange.upperBound
            )
        }
    }
}

/// One scope's rules, with its add-rule menu for missing types.
private struct ScopeGroupView: View {
    let group: AlertsConfigViewModel.ScopeGroup
    let viewModel: AlertsConfigViewModel

    private var missingTypes: [AlertRuleType] {
        AlertRuleType.allCases.filter { type in
            !group.records.contains { $0.type == type }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(group.title.uppercased())
                    .font(.system(size: 10, weight: .bold)).tracking(1)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                if !missingTypes.isEmpty {
                    addMenu
                }
            }
            VStack(spacing: 0) {
                if group.records.isEmpty {
                    Text("No rules in this scope — add one with the menu above.")
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                } else {
                    ForEach(group.records) { record in
                        RuleRow(record: record, viewModel: viewModel)
                        if record.id != group.records.last?.id {
                            Divider().overlay(Color.white.opacity(0.06))
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.06)))
        }
    }

    private var addMenu: some View {
        Menu {
            ForEach(missingTypes, id: \.self) { type in
                Button(type.title) {
                    Task { await viewModel.addRule(type: type, scope: group.scope) }
                }
            }
        } label: {
            Label("Add rule", systemImage: "plus")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// The "Add scope" affordance: create a new scope group for a node **class** (picked
/// from `NodeClass.allCases`) or a specific **node** (entered as a decimal number or
/// `!aabbccdd` hex id). Adding a scope seeds its first default rule via the view
/// model so the group appears immediately and persists.
private struct AddScopeBar: View {
    let viewModel: AlertsConfigViewModel

    @State private var nodeText = ""

    /// Classes that don't already have a group, so we never offer a duplicate.
    private var availableClasses: [NodeClass] {
        let existing = Set(viewModel.groups.compactMap { group -> NodeClass? in
            if case let .nodeClass(nodeClass) = group.scope { return nodeClass }
            return nil
        })
        return NodeClass.allCases.filter { !existing.contains($0) }
    }

    private var parsedNode: UInt32? {
        AlertsConfigViewModel.parseNodeID(nodeText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ADD SCOPE")
                .font(.system(size: 10, weight: .bold)).tracking(1)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                classRow
                Divider().overlay(Color.white.opacity(0.06))
                nodeRow
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.06)))
        }
    }

    private var classRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Node class").font(.system(size: 13))
                Text("defaults for every node of a class")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 8)
            classMenu
        }
    }

    private var classMenu: some View {
        Menu {
            ForEach(availableClasses, id: \.self) { nodeClass in
                Button(nodeClass.rawValue.capitalized) {
                    Task { await viewModel.addScope(.nodeClass(nodeClass)) }
                }
            }
        } label: {
            Label("Add class", systemImage: "rectangle.3.group")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(availableClasses.isEmpty ? 0.3 : 0.8))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(availableClasses.isEmpty)
        .help(availableClasses.isEmpty ? "Every class already has a scope" : "Add a class scope")
    }

    private var nodeRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Specific node").font(.system(size: 13))
                Text("overrides for one node — number or !hex id")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 8)
            TextField("!a1b2c3d4", text: $nodeText)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 110)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.white.opacity(0.08)))
                .onSubmit(addNode)
            Button("Add", action: addNode)
                .buttonStyle(SettingsPrimaryButtonStyle(enabled: parsedNode != nil))
                .disabled(parsedNode == nil)
        }
    }

    private func addNode() {
        guard let num = parsedNode else { return }
        nodeText = ""
        Task { await viewModel.addScope(.node(num)) }
    }
}

/// One rule: type label, enable switch, threshold stepper, delete.
private struct RuleRow: View {
    let record: AlertRuleRecord
    let viewModel: AlertsConfigViewModel

    private var thresholdLabel: String {
        switch record.type {
        case .voltageBelow: String(format: "%.1f%@", record.threshold, record.type.unit)
        default: String(format: "%.0f%@", record.threshold, record.type.unit)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            enableToggle
            Text(record.type.title)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(record.enabled ? 1 : 0.45))
            Spacer(minLength: 8)
            stepper
            deleteButton
        }
        .padding(.vertical, 9)
    }

    private var enableToggle: some View {
        Toggle("", isOn: Binding(
            get: { record.enabled },
            set: { value in
                Task { await viewModel.setEnabled(value, scope: record.scope, type: record.type) }
            }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private var stepper: some View {
        HStack(spacing: 8) {
            stepButton("minus", enabled: record.enabled) {
                Task { await viewModel.stepThreshold(by: -1, scope: record.scope, type: record.type) }
            }
            Text(thresholdLabel)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(record.enabled ? 1 : 0.45))
                .frame(minWidth: 52)
            stepButton("plus", enabled: record.enabled) {
                Task { await viewModel.stepThreshold(by: 1, scope: record.scope, type: record.type) }
            }
        }
    }

    private var deleteButton: some View {
        Button {
            Task { await viewModel.deleteRule(scope: record.scope, type: record.type) }
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.5))
                .frame(width: 24, height: 24)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("Delete rule")
    }

    private func stepButton(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(enabled ? 0.85 : 0.25))
                .frame(width: 24, height: 24)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

#if DEBUG
    @MainActor private func previewAlertsViewModel() -> AlertsConfigViewModel {
        let store = InMemoryAlertRuleStore([
            AlertRuleRecord(scope: .global, type: .batteryBelow, threshold: 20),
            AlertRuleRecord(scope: .global, type: .stale, threshold: 24),
            AlertRuleRecord(scope: .nodeClass(.mobile), type: .stale, threshold: 6),
            AlertRuleRecord(scope: .nodeClass(.fixed), type: .batteryBelow, threshold: 15, enabled: false),
            AlertRuleRecord(scope: .node(0xA1B2_C3D4), type: .voltageBelow, threshold: 3.4)
        ])
        return AlertsConfigViewModel(rules: store)
    }

    #Preview("Alerts config") {
        let viewModel = previewAlertsViewModel()
        return AlertsConfigView(viewModel: viewModel)
            .frame(width: 600, height: 700)
            .task { await viewModel.load() }
    }

    #Preview("Alerts config — empty store") {
        let viewModel = AlertsConfigViewModel(rules: InMemoryAlertRuleStore())
        return AlertsConfigView(viewModel: viewModel)
            .frame(width: 600, height: 700)
            .task { await viewModel.load() }
    }
#endif
