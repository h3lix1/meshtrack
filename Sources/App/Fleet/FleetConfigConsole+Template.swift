// FleetConfigConsole+Template — the broad-config surface of the template editor
// (Phase 10). Split out of `FleetConfigConsole` so the console's type body stays
// within the lint cap.
//
// This is where a template gains parity with the per-node editor: it renders the
// SAME bespoke `NodeConfigSectionView` sections (Device/LoRa/Position/Power/Display/
// Network/Bluetooth/Security/Modules), bound to the view model's `configForm`, so the
// operator can set any protocol field as a group default. The form is always "armed"
// here — a template editor is always editing — and only the keys actually set are
// carried (the per-node editor's diff semantics don't apply to a template).

import SwiftUI

extension FleetConfigConsole {
    /// Every broad-config section, bound to the view model's shared `configForm`.
    /// Mutations land in `configForm.values`; `FleetConfigViewModel.saveTemplate()` /
    /// `preview()` fold those into the template the rollout applies. A per-node edit
    /// later overrides these defaults on top.
    var broadConfigSections: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DEFAULTS").font(.system(size: 10, weight: .bold)).tracking(1)
                .foregroundStyle(.secondary)
            Text("Group defaults the rollout applies; a node's own config edit overrides them.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            ForEach(NodeConfigForm.sections) { section in
                NodeConfigSectionView(
                    section: section,
                    form: viewModel.configForm,
                    armed: true,
                    isExpanded: expandedSections.contains(section.title),
                    onToggleExpand: { toggleTemplateSection(section.title) }
                )
            }
        }
    }

    func toggleTemplateSection(_ title: String) {
        if expandedSections.contains(title) {
            expandedSections.remove(title)
        } else {
            expandedSections.insert(title)
        }
    }
}
