// PacketWindowPreference — the view-layer persistence for the packet inspector's
// configurable window size (item 7). A thin `UserDefaults` shim, deliberately NOT
// `@AppStorage`: property-wrapper access during the headless ImageRenderer render
// pass crashes the snapshot gate, so the section restores the saved value off the
// render pass (a deferred `onAppear`) and the filter bar persists on tap. No
// Domain/Persistence schema change — this is screen-local UI state only.

import Foundation

public enum PacketWindowPreference {
    /// The selectable window caps offered by the bespoke segmented control.
    public static let options = [50, 100, 200, 500, 1000]

    /// The default cap when nothing is persisted (matches the VM's `init` default).
    public static let defaultSize = 200

    private static let key = "packetInspector.windowSize"

    /// The saved window cap, or `defaultSize` when unset / out of the offered range.
    /// Public so it can seed `PacketInspectorViewModel.init`'s default argument (the
    /// render-safe restore path, since view-lifecycle hooks crash the snapshot gate).
    public static func restore(from defaults: UserDefaults = .standard) -> Int {
        let saved = defaults.integer(forKey: key) // 0 when the key is absent
        return options.contains(saved) ? saved : defaultSize
    }

    /// Persist the chosen window cap.
    public static func persist(_ size: Int, to defaults: UserDefaults = .standard) {
        defaults.set(size, forKey: key)
    }
}
