// AlertsConsoleView — the alerts console (G5). Bespoke dark-theme views (no stock
// controls / ScrollView chrome) so the headless ImageRenderer snapshot renders
// faithfully (memory: stock controls render badly headless).
//
// Three regions:
//  1. Alert feed grouped by state (firing / acknowledged / resolved) with per-row
//     ack / snooze / resolve actions and cooldown / snooze-remaining badges.
//  2. Managed-aware suppression explainer: which observed nodes don't raise
//     battery/stale alerts, and why (ADR 0008) — so a quiet stranger is explained.
//  3. The arming flow (capture anchor / disarm; armed / anchored / moved /
//     returned state).
//
// The view is driven by the two `@MainActor @Observable` view models; the harness
// can also build it from plain item arrays for deterministic snapshots.

import Domain
import SwiftUI

private enum Palette {
    static let background = Color(red: 0.03, green: 0.04, blue: 0.10)
    static let card = Color.white.opacity(0.04)
    static func severityTint(_ severity: Int) -> Color {
        switch severity {
        case 5: .purple
        case 4: .red
        case 3: .orange
        case 2: .yellow
        default: .cyan
        }
    }

    static func stateTint(_ state: AlertState) -> Color {
        switch state {
        case .firing: .red
        case .acknowledged: .orange
        case .resolved: .green
        }
    }
}

public struct AlertsConsoleView: View {
    private let firing: [AlertConsoleItem]
    private let acknowledged: [AlertConsoleItem]
    private let resolved: [AlertConsoleItem]
    private let suppressed: [SuppressedNode]
    private let arming: [ArmingDisplay]

    private let onAcknowledge: (AlertConsoleItem) -> Void
    private let onSnooze: (AlertConsoleItem) -> Void
    private let onResolve: (AlertConsoleItem) -> Void

    /// Build directly from item arrays (snapshot harness + previews).
    public init(
        firing: [AlertConsoleItem],
        acknowledged: [AlertConsoleItem] = [],
        resolved: [AlertConsoleItem] = [],
        suppressed: [SuppressedNode] = [],
        arming: [ArmingDisplay] = [],
        onAcknowledge: @escaping (AlertConsoleItem) -> Void = { _ in },
        onSnooze: @escaping (AlertConsoleItem) -> Void = { _ in },
        onResolve: @escaping (AlertConsoleItem) -> Void = { _ in }
    ) {
        self.firing = firing
        self.acknowledged = acknowledged
        self.resolved = resolved
        self.suppressed = suppressed
        self.arming = arming
        self.onAcknowledge = onAcknowledge
        self.onSnooze = onSnooze
        self.onResolve = onResolve
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !firing.isEmpty {
                    group("FIRING", items: firing, tint: .red, actionable: true)
                }
                if !acknowledged.isEmpty {
                    group("ACKNOWLEDGED", items: acknowledged, tint: .orange, actionable: false)
                }
                if !resolved.isEmpty {
                    group("RESOLVED", items: resolved, tint: .green, actionable: false)
                }
                if firing.isEmpty, acknowledged.isEmpty, resolved.isEmpty {
                    emptyState
                }
                if !suppressed.isEmpty { suppressionExplainer }
                if !arming.isEmpty { armingSection }
            }
            .padding(20)
        }
        .background(Palette.background)
        .foregroundStyle(.white)
    }

    // MARK: Groups

    private func group(
        _ title: String,
        items: [AlertConsoleItem],
        tint: Color,
        actionable: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title).font(.system(size: 11, weight: .bold)).tracking(1.5).foregroundStyle(tint)
                Text("\(items.count)")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(tint.opacity(0.18), in: Capsule()).foregroundStyle(tint)
                Spacer()
            }
            ForEach(items) { item in
                AlertConsoleRow(
                    item: item,
                    actionable: actionable,
                    onAcknowledge: onAcknowledge,
                    onSnooze: onSnooze,
                    onResolve: onResolve
                )
            }
        }
    }

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
            Text("No active alerts — the fleet is healthy.")
                .font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Suppression explainer (ADR 0008)

    private var suppressionExplainer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "bell.slash.fill").foregroundStyle(.secondary)
                Text("MANAGED-AWARE SUPPRESSION")
                    .font(.system(size: 11, weight: .bold)).tracking(1.5).foregroundStyle(.secondary)
            }
            Text("Unmanaged nodes are observed read-only — they never raise battery, "
                + "voltage, or stale alerts, so you don't get false alarms for nodes "
                + "you don't run. \(suppressed.count) node\(suppressed.count == 1 ? "" : "s") suppressed:")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7)).fixedSize(
                    horizontal: false,
                    vertical: true
                )
            ForEach(suppressed) { node in
                HStack(spacing: 10) {
                    Image(systemName: "moon.zzz.fill").font(.caption).foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(node.nodeName).font(.system(size: 12, design: .monospaced))
                    Spacer()
                    Text(node.reason).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: Arming flow

    private var armingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "scope").foregroundStyle(.cyan)
                Text("MOVEMENT ARMING")
                    .font(.system(size: 11, weight: .bold)).tracking(1.5).foregroundStyle(.cyan)
            }
            ForEach(arming) { row in ArmingRowView(row: row) }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct AlertConsoleRow: View {
    let item: AlertConsoleItem
    let actionable: Bool
    let onAcknowledge: (AlertConsoleItem) -> Void
    let onSnooze: (AlertConsoleItem) -> Void
    let onResolve: (AlertConsoleItem) -> Void

    private var tint: Color {
        Palette.severityTint(item.severity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(tint).font(.title3).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.type.rawValue).font(.system(size: 14, weight: .semibold))
                    Text(item.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(item.nodeName).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
            }
            HStack(spacing: 8) {
                badge(item.state.rawValue.uppercased(), color: Palette.stateTint(item.state))
                if let snooze = item.snoozeRemaining {
                    badge("SNOOZED \(Format.duration(snooze))", color: .indigo)
                }
                if let cooldown = item.cooldownRemaining {
                    badge("COOLDOWN \(Format.duration(cooldown))", color: .teal)
                }
                Spacer()
                if actionable { actions }
            }
        }
        .padding(14)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) {
            Rectangle().fill(tint).frame(width: 3).clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            actionButton("Ack", system: "hand.raised.fill", tint: .orange) { onAcknowledge(item) }
            actionButton("Snooze", system: "moon.zzz.fill", tint: .indigo) { onSnooze(item) }
            actionButton("Resolve", system: "checkmark.circle.fill", tint: .green) { onResolve(item) }
        }
    }

    private func actionButton(
        _ title: String,
        system: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: system)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(tint.opacity(0.18), in: Capsule()).foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule()).foregroundStyle(color)
    }
}

struct ArmingRowView: View {
    let row: ArmingDisplay

    private var stateTint: Color {
        switch row.state {
        case .anchored: .green
        case .moved: .red
        case .returned: .cyan
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.armed ? "lock.fill" : "lock.open.fill")
                .foregroundStyle(row.armed ? .orange : .secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.nodeName).font(.system(size: 13, design: .monospaced))
                if let anchor = row.anchor {
                    Text(String(
                        format: "anchor %.4f, %.4f · %.0fm",
                        anchor.lat,
                        anchor.lon,
                        row.thresholdMeters
                    ))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    Text("no anchor captured").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(row.state.rawValue.uppercased())
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(stateTint.opacity(0.18), in: Capsule()).foregroundStyle(stateTint)
        }
        .padding(10)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 9))
    }
}

/// Pure, locale-independent duration formatting for the badges (testable).
enum Format {
    static func duration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total >= 3600 { return "\(total / 3600)h \((total % 3600) / 60)m" }
        if total >= 60 { return "\(total / 60)m \(total % 60)s" }
        return "\(total)s"
    }
}
