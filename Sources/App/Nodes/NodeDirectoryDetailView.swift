// NodeDirectoryDetailView — click-to-configure node detail (Phase 7 G3).
//
// The richer detail panel the directory drills into: identity + ownership chips, a
// share QR (`CIQRCodeGenerator`), a config form gated behind the same ARM safety
// toggle as `NodeDetailView` (nothing writes until the operator arms), and an
// "Open analytics" hook that surfaces the node id back to the host so the lead can
// link it to G4's `NodeAnalyticsView`.
//
// Bespoke chips / switches (no stock controls) so the dark theme is consistent and
// the headless ImageRenderer snapshot renders faithfully (memory: stock controls
// render badly headless).

import Provisioning
import SwiftUI

public struct NodeDirectoryDetailView: View {
    public let entry: NodeDirectoryEntry
    /// Apply the (armed) config edit through the verified rolling update.
    public var onApply: (NodeConfigEdit) -> Void
    /// Drill through to analytics for this node (G4 seam) — the host links it to
    /// `NodeAnalyticsView`.
    public var onOpenAnalytics: (Int64) -> Void
    /// Flip an ownership flag for this single node (delegates to the VM /
    /// `setOwnership`). `isMine` / `isManaged` are passed through unchanged when
    /// `nil`.
    public var onSetOwnership: (_ isMine: Bool?, _ isManaged: Bool?) -> Void
    /// Run an imperative node command (favorite / unfavorite / ignore / unignore)
    /// over the admin path. The host wires it to a `MeshAdminChannel.send(_:)`.
    public var onCommand: (NodeAdminCommand) -> Void

    // Internal (not private) so the config-form + remote-action sections, split into
    // `NodeDirectoryDetailView+Config.swift` to stay within the lint type-body cap,
    // can read/mutate this same state.
    @State var name: String
    @State var armed: Bool
    /// Which broad-config sections are expanded (collapsible-ish, snapshot-safe).
    @State var expanded: Set<String>
    /// Whether this node is currently a favourite (drives the ☆/★ action).
    @State var isFavorite: Bool
    @State var form: NodeConfigFormState

    public init(
        entry: NodeDirectoryEntry,
        region: String = "US",
        role: String = "CLIENT",
        baseline: [String: String] = [:],
        isFavorite: Bool = false,
        armedForPreview: Bool = false,
        expandedSections: Set<String> = ["LoRa"],
        onApply: @escaping (NodeConfigEdit) -> Void = { _ in },
        onOpenAnalytics: @escaping (Int64) -> Void = { _ in },
        onSetOwnership: @escaping (_ isMine: Bool?, _ isManaged: Bool?) -> Void = { _, _ in },
        onCommand: @escaping (NodeAdminCommand) -> Void = { _ in }
    ) {
        self.entry = entry
        self.onApply = onApply
        self.onOpenAnalytics = onOpenAnalytics
        self.onSetOwnership = onSetOwnership
        self.onCommand = onCommand
        _name = State(initialValue: entry.name)
        _armed = State(initialValue: armedForPreview)
        _expanded = State(initialValue: expandedSections)
        _isFavorite = State(initialValue: isFavorite)
        // Seed the form's baseline from the supplied snapshot, defaulting region/role
        // so the legacy two-field edit keeps a sensible starting point.
        var seed = baseline
        seed["region"] = seed["region"] ?? region
        seed["role"] = seed["role"] ?? role
        _form = State(initialValue: NodeConfigFormState(baseline: seed))
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(.white.opacity(0.1))
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    identityRow
                    ownershipSection
                    favoriteSection
                    configForm
                    armingSection
                    Spacer(minLength: 0)
                }
                .padding(20)
            }
        }
        .frame(width: 440, height: 760)
        .background(Color(red: 0.05, green: 0.06, blue: 0.14))
        .foregroundStyle(.white)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Circle().fill(entry.role == .gateway ? Color.cyan : .blue).frame(width: 11, height: 11)
                .shadow(color: entry.role == .gateway ? .cyan : .blue, radius: 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.system(size: 17, weight: .bold))
                Text(entry.hexID).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            Spacer()
            roleBadge
        }
        .padding(18)
    }

    private var roleBadge: some View {
        Text(entry.role.label.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(.cyan.opacity(0.18), in: Capsule()).foregroundStyle(.cyan)
    }

    // MARK: Identity row (QR + open-analytics)

    private var identityRow: some View {
        HStack(alignment: .top, spacing: 16) {
            qrTile
            VStack(alignment: .leading, spacing: 12) {
                Text("SHARE").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.secondary)
                Text(NodeShareQR.shareURL(forNodeNum: entry.nodeNum))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                    .textSelection(.enabled)
                Button {
                    onOpenAnalytics(entry.nodeNum)
                } label: {
                    Label("Open analytics", systemImage: "chart.bar.xaxis")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.cyan)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var qrTile: some View {
        if let qrImage = NodeShareQR.nodeImage(nodeNum: entry.nodeNum, size: 220) {
            qrImage
                .interpolation(.none)
                .resizable()
                .frame(width: 110, height: 110)
                .padding(8)
                .background(.white, in: RoundedRectangle(cornerRadius: 10))
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(.white.opacity(0.06))
                .frame(width: 110, height: 110)
                .overlay(Image(systemName: "qrcode").font(.largeTitle).foregroundStyle(.secondary))
        }
    }

    // MARK: Ownership

    private var ownershipSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("OWNERSHIP").font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ownershipToggle(
                    title: "Mine",
                    systemImage: "person.fill",
                    isOn: entry.isMine,
                    tint: .blue
                ) { onSetOwnership(!entry.isMine, nil) }
                ownershipToggle(
                    title: "Managed",
                    systemImage: "gearshape.fill",
                    isOn: entry.isManaged,
                    tint: .green
                ) { onSetOwnership(nil, !entry.isManaged) }
            }
            Text(
                entry.isManaged
                    ? "Managed — battery / voltage / stale alerts evaluate for this node."
                    : "Observed only — no battery / silence alerts (ADR 0008)."
            )
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func ownershipToggle(
        title: String,
        systemImage: String,
        isOn: Bool,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                isOn ? tint.opacity(0.22) : .white.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(isOn ? tint : .clear, lineWidth: 1))
            .foregroundStyle(isOn ? tint : .white.opacity(0.7))
        }
        .buttonStyle(.plain)
    }

    // MARK: Arming gate (mirrors NodeDetailView)

    private var armingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { armed.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: armed ? "lock.open.fill" : "lock.fill")
                    Text(armed ? "ARMED — changes enabled" : "Safe — tap to arm")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Capsule().fill(armed ? Color.orange : .gray.opacity(0.4))
                        .frame(width: 42, height: 24)
                        .overlay(Circle().fill(.white).frame(width: 18, height: 18).offset(x: armed ? 9 : -9))
                }
                .foregroundStyle(armed ? .orange : .secondary)
            }
            .buttonStyle(.plain)

            Button {
                onApply(NodeConfigEdit(nodeNum: entry.nodeNum, name: name, fields: form.changedFields))
            } label: {
                Text("Apply via verified rolling update")
                    .font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        armed ? Color.cyan : .gray.opacity(0.3),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                    .foregroundStyle(armed ? .black : .white.opacity(0.4))
            }
            .buttonStyle(.plain).disabled(!armed)

            Text("Applies through AdminApplier: render → diff → write → read-back verify.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(armed ? .orange.opacity(0.5) : .clear, lineWidth: 1)
        )
    }
}
