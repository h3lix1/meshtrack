// NodeConfigControls — the bespoke, snapshot-safe controls the broad per-node config
// form renders (Phase 10).
//
// Memory: stock SwiftUI controls (Toggle / Picker / DisclosureGroup / ScrollView)
// render badly under the headless ImageRenderer snapshot gate, so the broad config
// form is built entirely from these hand-rolled pieces:
//   • NodeConfigSectionView — one collapsible config section (Device, LoRa, …),
//   • DirectoryChipPicker    — a one-of chip picker (enum fields),
//   • ConfigTogglePill       — an on/off pill (boolean fields),
//   • ConfigTextField        — a string/number value row.
// All consume `NodeConfigFormState` so an edit surfaces only the changed fields.

import SwiftUI

/// Chip picker mirroring `NodeDetailView`'s, scoped to the directory file so the
/// two streams never collide on a shared private type.
struct DirectoryChipPicker: View {
    let options: [String]
    @Binding var selection: String
    let enabled: Bool

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 86), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Text(option)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1).minimumScaleFactor(0.8)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(isSelected ? Color.cyan.opacity(0.22) : .white.opacity(0.05), in: Capsule())
                    .overlay(Capsule().stroke(isSelected ? Color.cyan : .clear, lineWidth: 1))
                    .foregroundStyle(isSelected ? .cyan : .white.opacity(enabled ? 0.7 : 0.35))
                    .onTapGesture { if enabled { selection = option } }
            }
        }
    }
}

/// One collapsible config section (Device, LoRa, …) of the broad per-node form.
/// Bespoke header + bespoke per-field controls (chip / pill toggle / text) so the
/// headless ImageRenderer snapshot stays faithful (no stock DisclosureGroup/Toggle).
struct NodeConfigSectionView: View {
    let section: NodeConfigSection
    @Bindable var form: NodeConfigFormState
    let armed: Bool
    let isExpanded: Bool
    let onToggleExpand: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 12 : 0) {
            sectionHeader
            if isExpanded {
                ForEach(section.fields) { field in
                    fieldRow(field)
                }
            }
        }
        .padding(12)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private var sectionHeader: some View {
        Button(action: onToggleExpand) {
            HStack(spacing: 8) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                Text(section.title.uppercased())
                    .font(.system(size: 11, weight: .bold)).tracking(1)
                Spacer()
                Text("\(section.fields.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.white.opacity(0.08), in: Capsule())
            }
            .foregroundStyle(.white.opacity(0.85))
        }
        .buttonStyle(.plain)
    }

    private func fieldRow(_ field: NodeConfigFieldSpec) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(field.label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
                Spacer()
            }
            control(for: field)
        }
    }

    @ViewBuilder
    private func control(for field: NodeConfigFieldSpec) -> some View {
        switch field.control {
        case let .choice(options):
            DirectoryChipPicker(
                options: options,
                selection: Binding(
                    get: { form.value(for: field) },
                    set: { form.set($0, for: field.key) }
                ),
                enabled: armed
            )
        case .toggle:
            ConfigTogglePill(
                isOn: form.value(for: field) == "true",
                enabled: armed,
                action: { if armed { form.toggle(field.key) } }
            )
        case let .text(numeric):
            ConfigTextField(
                value: Binding(
                    get: { form.value(for: field) },
                    set: { form.set($0, for: field.key) }
                ),
                numeric: numeric,
                enabled: armed
            )
        }
    }
}

/// A bespoke on/off pill for a boolean config field (no stock `Toggle`, for
/// snapshot fidelity).
struct ConfigTogglePill: View {
    let isOn: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(isOn ? "On" : "Off").font(.system(size: 11, weight: .semibold))
                Spacer()
                Capsule().fill(isOn ? Color.cyan : .gray.opacity(0.4))
                    .frame(width: 38, height: 22)
                    .overlay(Circle().fill(.white).frame(width: 16, height: 16).offset(x: isOn ? 8 : -8))
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.white.opacity(enabled ? 0.06 : 0.03), in: RoundedRectangle(cornerRadius: 8))
            .foregroundStyle(isOn ? .cyan : .white.opacity(enabled ? 0.7 : 0.35))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// A bespoke text field for string/number config values. A stock `TextField` is
/// used for editing (it renders acceptably here), but the chrome is hand-rolled so
/// the row matches the dark theme; when disarmed it is read-only.
struct ConfigTextField: View {
    @Binding var value: String
    let numeric: Bool
    let enabled: Bool

    var body: some View {
        HStack {
            if enabled {
                TextField(numeric ? "0" : "—", text: $value)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
            } else {
                Text(value.isEmpty ? "—" : value)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.white.opacity(enabled ? 0.06 : 0.03), in: RoundedRectangle(cornerRadius: 8))
    }
}
