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
    public var hopDuration: Double {
        didSet { hopDuration = min(Self.maxHopDuration, max(Self.minHopDuration, hopDuration)) }
    }

    /// When true, every edge of a journey finishes together (shorter hops draw
    /// slower); when false, hops draw one-after-another.
    public var equaliseFinish: Bool

    public static let minHopDuration: Double = 0.3
    public static let maxHopDuration: Double = 4.0

    public init(hopDuration: Double = 1.2, equaliseFinish: Bool = false) {
        self.hopDuration = min(Self.maxHopDuration, max(Self.minHopDuration, hopDuration))
        self.equaliseFinish = equaliseFinish
    }

    /// The timing mode the TraceRenderer/TraceTiming use.
    public var mode: TraceTimingMode {
        equaliseFinish ? .equaliseFinish : .sequential
    }
}
