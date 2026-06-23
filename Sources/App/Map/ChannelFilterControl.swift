// ChannelFilterControl — the floating channel picker over the map (Task 4). A compact
// menu offering "All channels" plus every preset live nodes have been seen on, bound
// to the shared ChannelFilter. Live-app control surface; the headless snapshot path
// renders the Canvas map (DashboardView) per ADR 0007.

#if canImport(MapKit) && os(macOS)
    import SwiftUI

    public struct ChannelFilterControl: View {
        @Bindable private var filter: ChannelFilter
        private let presets: [ChannelPreset]

        public init(filter: ChannelFilter, presets: [ChannelPreset]) {
            _filter = Bindable(filter)
            self.presets = presets
        }

        public var body: some View {
            Menu {
                Button {
                    filter.selection = nil
                } label: {
                    Label("All channels", systemImage: filter.selection == nil ? "checkmark" : "")
                }
                if !presets.isEmpty {
                    Divider()
                    ForEach(presets) { preset in
                        Button {
                            filter.selection = preset
                        } label: {
                            Label(
                                preset.displayName,
                                systemImage: filter.selection == preset ? "checkmark" : ""
                            )
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                    Text(filter.selection?.displayName ?? "All channels")
                        .font(.caption.weight(.medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .background(.black.opacity(0.55), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
            .foregroundStyle(.white)
        }
    }
#endif
