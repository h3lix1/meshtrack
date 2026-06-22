// LiveConfigRevision — an observable "the live config changed" signal (Finding 1).
//
// The phase-7 review flagged that saving a connectable broker from Settings does
// not bring the running app live without a relaunch: the composition root resolves
// the broker config once on launch and never re-runs. This is the seam that closes
// that gap WITHOUT the App library importing the executable's `LiveCoordinator`.
//
// The connection-settings save path (and the data-source change) `bump()`s the
// revision on success; the executable's `ContentView` observes `token` via
// `.onChange` and re-runs its idempotent `resolveAndApply()` — so a saved broker
// goes live immediately, and changing the active source restarts the stream. Pure
// `@MainActor @Observable` value in the snapshot-pure App library; no Transport.

import Observation

/// A monotonically-increasing revision token published whenever the live
/// configuration changes (broker saved, data source switched). Observers re-resolve
/// when the token changes. `@MainActor` because both the writer (Settings save) and
/// the reader (the SwiftUI shell) live on the main actor.
@MainActor
@Observable
public final class LiveConfigRevision {
    /// The current revision. Starts at 0 and increases by one per `bump()`. Callers
    /// observe this via SwiftUI `.onChange` to re-run config resolution.
    public private(set) var token = 0

    public init() {}

    /// Signal that the live configuration changed (e.g. a successful Settings save or
    /// a data-source switch). Increments `token`, triggering a reconnect re-resolve.
    public func bump() {
        token += 1
    }
}
