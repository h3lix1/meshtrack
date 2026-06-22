// VizSettings — the observable model behind the map's viz-settings panel (SPEC §1.6).
// Holds the configurable hop draw time and the "equalise finish" toggle, and derives
// the TraceTimingMode the renderer consumes. Main-actor @Observable so the panel and
// the overlay stay in sync; the derived `mode` keeps the pure timing math the single
// source of truth.

import Foundation
import Observation

@MainActor
@Observable
public final class VizSettings {
    /// Seconds one hop edge takes to draw. Bounded to a sane, demo-friendly range.
    ///
    /// Backed by a private store with a clamping setter. We cannot use `didSet` to
    /// clamp here: `@Observable` rewrites stored properties into computed ones, so a
    /// `didSet` that assigns to `self` re-enters the synthesized setter and recurses
    /// forever (the "no recursive didSet" rule only applies to truly stored
    /// properties). Wiring the registrar manually keeps the value observed *and*
    /// clamped without recursion.
    @ObservationIgnored private var _hopDuration: Double

    public var hopDuration: Double {
        get {
            access(keyPath: \.hopDuration)
            return _hopDuration
        }
        set {
            withMutation(keyPath: \.hopDuration) {
                _hopDuration = min(Self.maxHopDuration, max(Self.minHopDuration, newValue))
            }
        }
    }

    /// When true, every edge of a journey finishes together (shorter hops draw
    /// slower); when false, hops draw one-after-another.
    public var equaliseFinish: Bool

    /// When true and a packet is focused, the map rings EVERY node that received the
    /// packet — including non-repeaters / last hops that heard it but never
    /// rebroadcast — each annotated with the hop at which it received it (item 6).
    public var showAllReceivers: Bool

    public static let minHopDuration: Double = 0.3
    public static let maxHopDuration: Double = 4.0

    public init(
        hopDuration: Double = 1.2,
        equaliseFinish: Bool = false,
        showAllReceivers: Bool = false
    ) {
        _hopDuration = min(Self.maxHopDuration, max(Self.minHopDuration, hopDuration))
        self.equaliseFinish = equaliseFinish
        self.showAllReceivers = showAllReceivers
    }

    /// The timing mode the TraceRenderer/TraceTiming use.
    public var mode: TraceTimingMode {
        equaliseFinish ? .equaliseFinish : .sequential
    }
}
