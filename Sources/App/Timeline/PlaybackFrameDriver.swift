// PlaybackFrameDriver — the per-frame clock that actually moves the playhead (G9).
//
// `TimelineViewModel.tick(delta:)` advances the playhead while playing, but nothing
// called it: pressing Play set `isPlaying` and never moved. This drives `tick` once
// per frame from a `TimelineView(.animation)`, feeding it the real-seconds delta
// between successive frame dates.
//
// The delta math is split into a pure `FrameDelta` helper so it can be unit-tested
// without a running render loop: the first frame (no previous date) yields no step,
// and an over-long gap (tab backgrounded, render hitch) is clamped so playback
// doesn't lurch forward by seconds in a single tick.

import SwiftUI

/// Pure frame-to-frame delta computation for the playback driver. Holds the last
/// frame's date and, given the next one, returns the real-seconds delta to feed
/// `tick(delta:)` — guarding the first frame and clamping over-long gaps.
struct FrameDelta {
    /// The largest single-frame step we forward to `tick`. A backgrounded tab or a
    /// render hitch can leave a multi-second gap between frames; without a clamp the
    /// playhead would jump that whole gap (× speed) at once. ~4 frames at 60Hz.
    static let maxStep: Double = 1.0 / 15.0

    /// The previous frame's timestamp, or nil before the first frame is seen.
    private(set) var previous: Date?

    init(previous: Date? = nil) {
        self.previous = previous
    }

    /// Advance to `frame`, returning the clamped real-seconds delta since the last
    /// frame. The first frame (no previous) returns 0 so playback can't jump on the
    /// very first tick; a negative or zero gap also returns 0.
    mutating func step(to frame: Date) -> Double {
        defer { previous = frame }
        guard let previous else { return 0 }
        let raw = frame.timeIntervalSince(previous)
        guard raw > 0 else { return 0 }
        return min(raw, Self.maxStep)
    }
}

/// A zero-size view that ticks `onTick` once per animation frame while active.
/// Embed it (e.g. as a background) only while playing; SwiftUI tears down the
/// `TimelineView` schedule when it leaves the hierarchy, so ticking stops cleanly
/// when paused. The first frame after appearing is absorbed (delta 0) so resuming
/// playback never lurches.
struct PlaybackTickDriver: View {
    /// Receives the clamped real-seconds delta since the previous frame.
    let onTick: (Double) -> Void

    @State private var delta = FrameDelta()

    var body: some View {
        TimelineView(.animation) { context in
            // Canvas content must be a View; an empty Color is inert + zero-cost.
            Color.clear
                .onChange(of: context.date) { _, date in
                    let seconds = delta.step(to: date)
                    if seconds > 0 { onTick(seconds) }
                }
        }
    }
}
