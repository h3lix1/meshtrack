// FleetRolloutView — the live UI for a safe rolling fleet rollout (SPEC §2.7, G7).
// Drives a `FleetRolloutViewModel`: a fleet-wide edit affordance (apply ONE
// template across the selected nodes), a dry-run diff preview per node, and the
// rolling rollout that verifies each node before the next and halts on failure —
// surfaced as live per-node status, an overall verified/total progress bar, and
// an abort control.
//
// Built with bespoke views (no stock controls / ScrollView) so it renders
// deterministically under the headless ImageRenderer snapshot gate, matching the
// existing `FleetConfigView` look it supersedes.

import Provisioning
import SwiftUI

public struct FleetRolloutView: View {
    @Bindable private var viewModel: FleetRolloutViewModel

    public init(viewModel: FleetRolloutViewModel) {
        self.viewModel = viewModel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            templateBanner
            progressBar
            rows
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.03, green: 0.04, blue: 0.10))
    }

    // MARK: Header + actions

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Fleet Configuration").font(.title.bold()).foregroundStyle(.white)
                Text("Each node is verified before the next, so a bad change can't destabilise the fleet.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            actions
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            if viewModel.isRolling {
                FleetActionButton(title: "Abort", systemImage: "stop.fill", tint: .red) {
                    viewModel.abort()
                }
            } else {
                FleetActionButton(title: "Preview", systemImage: "eye", tint: .cyan) {
                    Task { await viewModel.preview() }
                }
                FleetActionButton(title: "Roll Out", systemImage: "play.fill", tint: .green) {
                    viewModel.startRollout()
                }
            }
        }
    }

    // MARK: Fleet-wide edit affordance (apply one template across selected nodes)

    private var templateBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "slider.horizontal.3").foregroundStyle(.cyan).font(.system(size: 18))
            VStack(alignment: .leading, spacing: 3) {
                Text(templateHeadline)
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Text(templateSummary).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            HaltBadge(on: viewModel.haltOnFailure)
        }
        .padding(.horizontal, 16).padding(.vertical, 13)
        .background(.cyan.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.cyan.opacity(0.25), lineWidth: 1))
    }

    private var templateHeadline: String {
        let suffix = viewModel.total == 1 ? "" : "s"
        return "Applying template “\(viewModel.template.name)” to \(viewModel.total) node\(suffix)"
    }

    private var templateSummary: String {
        var parts = ["region \(viewModel.template.region)"]
        if let role = viewModel.template.role { parts.append("role \(role)") }
        if let bits = viewModel.template.positionPrecisionBits { parts.append("position \(bits)b") }
        return parts.joined(separator: " · ")
    }

    // MARK: Progress

    private var progressBar: some View {
        HStack(spacing: 12) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule().fill(viewModel.hasFailure ? Color.red : .green)
                        .frame(width: geo.size.width * viewModel.progress)
                }
            }
            .frame(height: 8)
            Text("\(viewModel.verifiedCount)/\(viewModel.total) verified")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(viewModel.hasFailure ? Color.red : .green)
                .fixedSize()
        }
    }

    // MARK: Rows

    private var rows: some View {
        VStack(spacing: 8) {
            ForEach(viewModel.rows) { FleetRolloutRowView(row: $0) }
        }
    }
}

// MARK: - Row

struct FleetRolloutRowView: View {
    let row: FleetRolloutViewModel.Row

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(label).font(.system(size: 9, weight: .bold)).foregroundStyle(color)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    /// The per-node diff summary (preview) or the failure reason.
    private var detail: String {
        switch row.status {
        case let .failed(reason):
            return reason
        case .noChange:
            return "already matches the template"
        default:
            guard !row.changes.isEmpty else { return "" }
            let fields = row.changes.prefix(3).map(\.field).joined(separator: ", ")
            let extra = row.changes.count > 3 ? " +\(row.changes.count - 3)" : ""
            return "\(row.changes.count) change\(row.changes.count == 1 ? "" : "s"): \(fields)\(extra)"
        }
    }

    private var label: String {
        switch row.status {
        case .pending: "PENDING"
        case .applying: "APPLYING"
        case .verified: "VERIFIED"
        case .noChange: "NO CHANGE"
        case .failed: "FAILED"
        }
    }

    private var color: Color {
        switch row.status {
        case .verified, .noChange: .green
        case .applying: .cyan
        case .pending: .gray
        case .failed: .red
        }
    }

    private var icon: String {
        switch row.status {
        case .verified: "checkmark.circle.fill"
        case .noChange: "equal.circle.fill"
        case .applying: "arrow.triangle.2.circlepath"
        case .pending: "circle"
        case .failed: "xmark.circle.fill"
        }
    }
}

// MARK: - Bespoke controls (snapshot-deterministic)

/// A bespoke action button (not a stock `Button` style) so it renders under the
/// headless snapshot gate.
struct FleetActionButton: View {
    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 11, weight: .bold))
                Text(title).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Shows whether the rollout halts on the first failure (the safe default).
struct HaltBadge: View {
    let halting: Bool

    init(on halting: Bool) {
        self.halting = halting
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: halting ? "shield.lefthalf.filled" : "shield.slash")
                .font(.system(size: 10, weight: .bold))
            Text(halting ? "halt on failure" : "continue on failure")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(halting ? Color.green : .orange)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background((halting ? Color.green : .orange).opacity(0.12), in: Capsule())
    }
}
