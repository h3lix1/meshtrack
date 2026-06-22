// FleetConfigConsole — the real Fleet Configuration UI (SPEC §2.7), replacing the
// sample-fed demo. Left: manage/edit reusable templates. Right: target nodes, preview
// each node's diff, and run a safe rolling rollout (verify each before the next, halt
// on failure). Driven by `FleetConfigViewModel`; the rollout itself reuses the G7
// `FleetRolloutView`. This is the live-app view (not the headless snapshot path), so
// it uses stock controls.

import SwiftUI

public struct FleetConfigConsole: View {
    /// Internal (not private) so the broad-config editor section, split into
    /// `FleetConfigConsole+Template.swift` to keep this type body within the lint cap,
    /// can read it.
    @State var viewModel: FleetConfigViewModel
    /// Which broad-config sections are expanded in the template editor (collapsible).
    @State var expandedSections: Set<String> = ["LoRa"]

    public init(viewModel: FleetConfigViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            templatePane
                .frame(width: 380)
            Divider().overlay(Color.white.opacity(0.08))
            rolloutPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.03, green: 0.04, blue: 0.10))
        .foregroundStyle(.white)
        .task { await viewModel.load() }
    }

    // MARK: Template editor

    private var templatePane: some View {
        @Bindable var model = viewModel
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Templates").font(.title2.bold())

                if viewModel.templates.isEmpty {
                    Text("No templates yet — create one below.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack {
                    Picker("Template", selection: Binding(
                        get: { viewModel.selectedTemplateID },
                        set: { if let id = $0 { viewModel.select(id) } }
                    )) {
                        Text("New…").tag(Int64?.none)
                        ForEach(viewModel.templates) { item in
                            Text(item.template.name).tag(Int64?.some(item.id))
                        }
                    }
                    .labelsHidden()
                    Button("New") { viewModel.newTemplate() }
                }

                labeledField("Name", text: $model.draft.name)
                labeledField("Short-name DSL", text: $model.draft.shortNameDSL)
                labeledField("Long-name DSL", text: $model.draft.longNameDSL)
                labeledField("Channels (comma-separated)", text: $model.draft.channels)

                broadConfigSections

                HStack {
                    Button("Save template") { Task { await viewModel.saveTemplate() } }
                        .buttonStyle(.borderedProminent)
                    Button("Delete", role: .destructive) {
                        Task { await viewModel.deleteSelectedTemplate() }
                    }
                    .disabled(viewModel.selectedTemplateID == nil)
                }

                if let error = viewModel.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .background(Color(red: 0.05, green: 0.06, blue: 0.15))
    }

    private func labeledField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, text: text).textFieldStyle(.roundedBorder)
        }
    }

    // MARK: Targeting + rollout

    private var rolloutPane: some View {
        @Bindable var model = viewModel
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Roll out").font(.title.bold())
                    Text("Each node is verified before the next; the first failure halts the rollout.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Applies to Meshtrack's record — over-the-air admin is a hardware step.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                HStack(spacing: 16) {
                    Toggle("My Nodes", isOn: $model.showMineOnly)
                    Toggle("Managed", isOn: $model.showManagedOnly)
                    Toggle("Halt on failure", isOn: $model.haltOnFailure)
                    Spacer()
                    Button("Select all") { viewModel.selectAllVisible() }
                    Button("Clear") { viewModel.clearSelection() }
                }
                .toggleStyle(.switch)

                memberList

                HStack(spacing: 12) {
                    Button("Preview diffs") { Task { await viewModel.preview() } }
                        .disabled(!viewModel.canRollOut)
                    Button("Roll out \(viewModel.selected.count) node(s)") { viewModel.startRollout() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!viewModel.canRollOut)
                    if viewModel.rollout?.isRolling == true {
                        Button("Abort", role: .destructive) { viewModel.abort() }
                    }
                }

                if let rollout = viewModel.rollout {
                    FleetRolloutView(viewModel: rollout).frame(minHeight: 220)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
        }
    }

    private var memberList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Target nodes (\(viewModel.selected.count) selected)").font(.headline)
            if viewModel.visibleCandidates.isEmpty {
                Text(viewModel.candidates.isEmpty
                    ? "No nodes yet — they appear here once the mesh reports them."
                    : "No nodes match the current filter.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(viewModel.visibleCandidates) { candidate in
                Button {
                    viewModel.toggle(candidate.nodeNum)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: viewModel.selected.contains(candidate.nodeNum)
                            ? "checkmark.square.fill" : "square")
                            .foregroundStyle(viewModel.selected
                                .contains(candidate.nodeNum) ? .cyan : .secondary)
                        Text(candidate.name)
                        if candidate.isManaged {
                            Text("MANAGED").font(.system(size: 8, weight: .bold)).foregroundStyle(.green)
                        }
                        if candidate.isMine {
                            Text("MINE").font(.system(size: 8, weight: .bold)).foregroundStyle(.cyan)
                        }
                        Spacer()
                        Text(candidate.hexid).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 4)
                Divider().overlay(Color.white.opacity(0.05))
            }
        }
    }
}
