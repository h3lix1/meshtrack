// ProvisioningComponents — the bespoke building blocks for the provisioning
// workflow UI (SPEC §2.7). All hand-rolled (no stock button/field styles) so the
// guided flow renders deterministically under the headless ImageRenderer snapshot
// gate, matching the fleet-rollout view's look.

import Provisioning
import SwiftUI

// MARK: - Step indicator chip

struct StepChip: View {
    enum State {
        case done, current, upcoming
    }

    let title: String
    let state: State

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(background, in: Capsule())
            .overlay(Capsule().stroke(border, lineWidth: 1))
    }

    private var foreground: Color {
        switch state {
        case .done: .green
        case .current: .cyan
        case .upcoming: .gray
        }
    }

    private var background: Color {
        switch state {
        case .done: .green.opacity(0.12)
        case .current: .cyan.opacity(0.16)
        case .upcoming: .white.opacity(0.04)
        }
    }

    private var border: Color {
        switch state {
        case .done: .green.opacity(0.35)
        case .current: .cyan.opacity(0.5)
        case .upcoming: .white.opacity(0.08)
        }
    }
}

// MARK: - Target node row

struct TargetRow: View {
    let candidate: ProvisioningWorkflowViewModel.TargetCandidate
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? .cyan : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                    Text(candidate.hexID).font(.system(size: 10).monospaced()).foregroundStyle(.secondary)
                }
                if candidate.isNewlyDiscovered {
                    Text("NEW").font(.system(size: 8, weight: .bold)).foregroundStyle(.yellow)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.yellow.opacity(0.14), in: Capsule())
                }
                Spacer()
                if let role = candidate.role {
                    Text(role.uppercased()).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(
                selected ? Color.cyan.opacity(0.10) : .white.opacity(0.03),
                in: RoundedRectangle(cornerRadius: 10)
            )
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Color.cyan.opacity(0.4) : .white.opacity(0.06), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Diff list

struct DiffList: View {
    let changes: [ConfigChange]

    var body: some View {
        VStack(spacing: 6) {
            ForEach(changes, id: \.field) { change in
                HStack(spacing: 10) {
                    Text(change.field)
                        .font(.system(size: 12, weight: .semibold).monospaced())
                        .foregroundStyle(.white)
                        .frame(width: 150, alignment: .leading)
                    Text(change.from ?? "—")
                        .font(.system(size: 11).monospaced()).foregroundStyle(.red.opacity(0.8))
                    Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(.secondary)
                    Text(change.to)
                        .font(.system(size: 11).monospaced()).foregroundStyle(.green)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.white.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

// MARK: - Reboot warning

struct RebootWarning: View {
    let fields: [String]

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(.orange).font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text("Requires a reboot").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                Text("Changing \(fields.joined(separator: ", ")) restarts the node to take effect.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.orange.opacity(0.3), lineWidth: 1))
    }
}

// MARK: - Banners

struct InfoBanner: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint).font(.system(size: 18))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.3), lineWidth: 1))
    }
}

struct ProvisioningErrorBanner: View {
    let message: String

    var body: some View {
        InfoBanner(icon: "xmark.octagon.fill", tint: .red, title: "Something went wrong", message: message)
    }
}

// MARK: - Bespoke controls

/// A bespoke action button (not a stock `Button` style) so it renders under the
/// headless snapshot gate. Disabled buttons dim and ignore taps.
struct ProvisioningButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button {
            if enabled { action() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 11, weight: .bold))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(enabled ? tint : tint.opacity(0.4))
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(
                (enabled ? tint : tint.opacity(0.4)).opacity(0.14),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke((enabled ? tint : tint.opacity(0.4)).opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// A bespoke labeled text field (not `.roundedBorder`) so it renders headlessly.
struct ProvisioningField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.1), lineWidth: 1))
        }
    }
}
