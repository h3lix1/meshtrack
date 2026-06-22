// LiveStartupPolicy — the pure launch-time decision: should the app connect to the
// live feed automatically on launch? (Finding 2, SPEC §2.5.)
//
// The composition root resolves whether a source is connectable (a saved broker +
// password, or a local node with a device path) and reads the operator's
// `AppSettings.autoConnect` preference. This helper folds those two facts into one
// decision so the rule is testable headless in the snapshot-pure App library,
// rather than buried in the executable's `resolveAndApply`.
//
// The rule: connect on launch ONLY when the operator opted into auto-connect AND a
// source is actually connectable. With `autoConnect == false` the app stays offline
// at launch until the operator explicitly connects (the Connect affordance or a
// successful Settings save), even when a connectable source is saved.

import Domain

/// The pure launch-time connect decision.
public enum LiveStartupPolicy {
    /// Whether the live coordinator should auto-start on launch.
    ///
    /// - Parameters:
    ///   - settings: the persisted app settings (carries `autoConnect`).
    ///   - hasConnectableSource: whether a source is connectable right now (a saved
    ///     connectable broker + resolvable password, or a local node with a device).
    /// - Returns: `true` only when the operator opted into auto-connect AND a source
    ///   is connectable; `false` otherwise (stay offline until an explicit connect).
    public static func shouldConnectOnLaunch(
        settings: AppSettings,
        hasConnectableSource: Bool
    ) -> Bool {
        settings.autoConnect && hasConnectableSource
    }
}
