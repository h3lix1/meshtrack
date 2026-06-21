// NodeDirectoryView — the CoreScope-style node directory (Phase 7 G3).
//
// The public section view the lead wires into the AppModel registry. Renders over
// `NodeDirectoryViewModel`:
//   * a role tab bar (All / Client / Router / Repeater / …),
//   * a search field + a "My Nodes" toggle,
//   * managed / unmanaged segments with live counts,
//   * a multi-select grid + a bulk-classify action bar (mark mine / managed),
//   * a tap-through to `NodeDirectoryDetailView` (config + QR + analytics hook).
//
// Bespoke cards (LazyVGrid, no stock `List`) + a hand-rolled tab bar / search row
// so the section renders faithfully under the headless ImageRenderer snapshot gate.

import SwiftUI

public struct NodeDirectoryView: View {
    @State private var viewModel: NodeDirectoryViewModel
    @State private var detailEntry: NodeDirectoryEntry?

    /// Apply an (armed) config edit through the verified rolling update.
    private let onApply: (NodeConfigEdit) -> Void
    /// Drill through to analytics for a node (G4 seam — the lead links it to
    /// `NodeAnalyticsView`).
    private let onOpenAnalytics: (Int64) -> Void

    public init(
        viewModel: NodeDirectoryViewModel,
        onApply: @escaping (NodeConfigEdit) -> Void = { _ in },
        onOpenAnalytics: @escaping (Int64) -> Void = { _ in }
    ) {
        _viewModel = State(initialValue: viewModel)
        self.onApply = onApply
        self.onOpenAnalytics = onOpenAnalytics
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            titleRow
            controls
            roleTabs
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.03, green: 0.04, blue: 0.10))
        .foregroundStyle(.white)
        .task { try? await viewModel.load() }
        .sheet(item: $detailEntry) { entry in
            NodeDirectoryDetailView(
                entry: entry,
                onApply: onApply,
                onOpenAnalytics: { nodeNum in
                    detailEntry = nil
                    onOpenAnalytics(nodeNum)
                },
                onSetOwnership: { isMine, isManaged in
                    classifySingle(entry.nodeNum, isMine: isMine, isManaged: isManaged)
                }
            )
        }
    }

    // MARK: Title + segment counts

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Nodes").font(.system(size: 22, weight: .bold))
            Text("\(viewModel.totalCount) total · \(viewModel.myNodesCount) mine")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            segmentChip(.managed, color: .green)
            segmentChip(.unmanaged, color: .secondary)
        }
    }

    private func segmentChip(_ segment: OwnershipSegment, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(viewModel.count(in: segment)) \(segment.label.lowercased())")
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(.white.opacity(0.05), in: Capsule())
        .foregroundStyle(.white.opacity(0.85))
    }

    // MARK: Controls (search + my-nodes + bulk)

    private var controls: some View {
        HStack(spacing: 10) {
            searchField
            myNodesToggle
            Spacer()
            if !viewModel.selection.isEmpty {
                bulkBar
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("Search name or !hexid", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .frame(width: 220)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private var myNodesToggle: some View {
        Button { viewModel.myNodesOnly.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: viewModel.myNodesOnly ? "person.fill" : "person")
                Text("My Nodes").font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(
                viewModel.myNodesOnly ? Color.blue.opacity(0.25) : .white.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .foregroundStyle(viewModel.myNodesOnly ? .blue : .white.opacity(0.8))
        }
        .buttonStyle(.plain)
    }

    private var bulkBar: some View {
        HStack(spacing: 8) {
            Text("\(viewModel.selection.count) selected")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            bulkButton("Mark Mine", tint: .blue) { classify(isMine: true) }
            bulkButton("Mark Managed", tint: .green) { classify(isManaged: true) }
            bulkButton("Unmanage", tint: .orange) { classify(isManaged: false) }
            Button("Clear") { viewModel.clearSelection() }
                .buttonStyle(.plain)
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func bulkButton(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(tint.opacity(0.22), in: Capsule())
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }

    // MARK: Role tabs

    private var roleTabs: some View {
        HStack(spacing: 6) {
            roleTab(.all)
            ForEach(viewModel.presentRoles) { role in
                roleTab(.role(role))
            }
        }
    }

    private func roleTab(_ filter: RoleFilter) -> some View {
        let active = viewModel.roleFilter == filter
        return Button { viewModel.roleFilter = filter } label: {
            Text(filter.label)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(active ? Color.cyan.opacity(0.22) : .white.opacity(0.05), in: Capsule())
                .overlay(Capsule().stroke(active ? Color.cyan : .clear, lineWidth: 1))
                .foregroundStyle(active ? .cyan : .white.opacity(0.7))
        }
        .buttonStyle(.plain)
    }

    // MARK: Content (segmented grids)

    @ViewBuilder
    private var content: some View {
        if viewModel.visible.isEmpty {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 18) {
                segmentGrid(.managed)
                segmentGrid(.unmanaged)
            }
        }
    }

    @ViewBuilder
    private func segmentGrid(_ segment: OwnershipSegment) -> some View {
        let entries = viewModel.entries(in: segment)
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(segment.label.uppercased()) · \(entries.count)")
                    .font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(entries) { entry in
                        DirectoryCard(
                            entry: entry,
                            isSelected: viewModel.isSelected(entry.nodeNum),
                            onTap: { detailEntry = entry },
                            onToggleSelect: { viewModel.toggleSelection(entry.nodeNum) }
                        )
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
            Text("No nodes match the current filters").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Classify helpers

    private func classify(isMine: Bool? = nil, isManaged: Bool? = nil) {
        Task { try? await viewModel.classifySelection(isMine: isMine, isManaged: isManaged) }
    }

    private func classifySingle(_ nodeNum: Int64, isMine: Bool?, isManaged: Bool?) {
        Task {
            viewModel.clearSelection()
            viewModel.toggleSelection(nodeNum)
            _ = try? await viewModel.classifySelection(isMine: isMine, isManaged: isManaged)
            // Re-open the (now updated) detail so its toggles reflect the change.
            if let updated = viewModel.allEntries.first(where: { $0.nodeNum == nodeNum }) {
                detailEntry = updated
            }
        }
    }
}

/// One node card in the directory grid: identity, role, ownership badges, battery,
/// and a multi-select checkbox. Bespoke (no stock `List`/`Toggle`) for snapshot
/// fidelity.
private struct DirectoryCard: View {
    let entry: NodeDirectoryEntry
    let isSelected: Bool
    let onTap: () -> Void
    let onToggleSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(action: onToggleSelect) {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 14))
                        .foregroundStyle(isSelected ? .cyan : .white.opacity(0.4))
                }
                .buttonStyle(.plain)
                Circle().fill(entry.role == .gateway ? Color.cyan : .blue).frame(width: 9, height: 9)
                Text(entry.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Spacer()
                ownershipBadges
            }
            Text(entry.hexID).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                roleTag
                Spacer()
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(
                    isSelected ? Color.cyan.opacity(0.6) : .white.opacity(0.06),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }

    private var ownershipBadges: some View {
        HStack(spacing: 4) {
            if entry.isMine {
                badge("MINE", color: .blue)
            }
            if entry.isManaged {
                badge("MGD", color: .green)
            }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(color.opacity(0.22), in: Capsule())
            .foregroundStyle(color)
    }

    private var roleTag: some View {
        Text(entry.role.label)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(.white.opacity(0.06), in: Capsule())
            .foregroundStyle(.white.opacity(0.7))
    }
}

#Preview("Node Directory") {
    NodeDirectoryPreviewWrapper()
        .frame(width: 900, height: 640)
}

/// Wrapper so the `#Preview` builds the seeded view model without a throwing
/// expression at the macro site (mirrors the analytics preview).
private struct NodeDirectoryPreviewWrapper: View {
    @State private var viewModel: NodeDirectoryViewModel?

    var body: some View {
        Group {
            if let viewModel {
                NodeDirectoryView(viewModel: viewModel)
            } else {
                Color.clear
            }
        }
        .task {
            if let store = try? await NodeDirectoryPreview.seededStore() {
                viewModel = NodeDirectoryViewModel(store: store)
            }
        }
    }
}
