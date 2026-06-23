// NodeDirectoryDetailView+Config — the broad config-form + remote-action sections of
// the node detail panel (Phase 10), split out so the main view's type body stays
// within the lint cap. Pure view-builder members over the same `NodeConfigFormState`
// / favourite state the main view owns.

import Provisioning
import SwiftUI

extension NodeDirectoryDetailView {
    // MARK: Remote favorite / ignore (imperative admin commands)

    var favoriteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("REMOTE ACTIONS").font(.system(size: 10, weight: .bold)).tracking(1)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                favoriteButton
                ignoreButton
            }
            Text("Favourite pins the node in the mesh DB (exempt from eviction); ignore drops its traffic.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    var favoriteButton: some View {
        Button {
            let node = UInt32(truncatingIfNeeded: entry.nodeNum)
            onCommand(isFavorite ? .unfavorite(nodeNum: node) : .favorite(nodeNum: node))
            isFavorite.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                Text(isFavorite ? "Unfavorite" : "Favorite").font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                isFavorite ? Color.yellow.opacity(0.22) : .white.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(isFavorite ? .yellow : .clear, lineWidth: 1))
            .foregroundStyle(isFavorite ? .yellow : .white.opacity(0.7))
        }
        .buttonStyle(.plain)
    }

    var ignoreButton: some View {
        Button {
            onCommand(.ignore(nodeNum: UInt32(truncatingIfNeeded: entry.nodeNum)))
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "nosign")
                Text("Ignore").font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
            .foregroundStyle(.white.opacity(0.7))
        }
        .buttonStyle(.plain)
    }

    // MARK: Config form (broad surface, collapsible sections)

    var configForm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("CONFIGURATION").font(.system(size: 10, weight: .bold)).tracking(1)
                .foregroundStyle(.secondary)
            labeled("Name") {
                HStack {
                    Text(name).font(.system(size: 13, design: .monospaced))
                    Spacer()
                    Image(systemName: "pencil").font(.caption).foregroundStyle(armed ? .cyan : .secondary)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.white.opacity(armed ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            ForEach(NodeConfigForm.sections) { section in
                NodeConfigSectionView(
                    section: section,
                    form: form,
                    armed: armed,
                    isExpanded: expanded.contains(section.title),
                    onToggleExpand: { toggleSection(section.title) }
                )
            }
        }
    }

    func toggleSection(_ title: String) {
        if expanded.contains(title) { expanded.remove(title) } else { expanded.insert(title) }
    }

    func labeled(_ label: String, @ViewBuilder _ control: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
            control()
        }
    }
}
