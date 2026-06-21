// TimelineViewModel — the VCR / time-travel composition seam (G9, §1).
//
// Loads the last 24h of observations + node positions from the store, exposes a
// scrubbable playhead and playback state (playing/paused, speed ∈ {0.5,1,2,4}×,
// live vs review), and drives the animation clock by advancing the playhead via
// `tick(delta:)`. The active traces + clock the map (G1) consumes are derived by
// the pure ReplayReconstructor, so the VM holds no animation math itself.
//
// @MainActor @Observable; unit-tested over a seeded in-memory MeshStore with an
// InjectedClock for determinism. Snapshot-pure: imports only Domain/Persistence.

import Domain
import Foundation
import Observation
import Persistence

@Observable
@MainActor
public final class TimelineViewModel {
    // MARK: Published state (the map + scrubber read these)

    /// The traces active at the playhead — feed straight to `NetworkMapView.traces`.
    public private(set) var traces: [PacketTrace] = []
    /// The animation clock at the playhead — feed to `NetworkMapView.clock`.
    public private(set) var clock: Double = 0
    /// Positioned nodes for the map (same seam as NetworkViewModel).
    public private(set) var nodes: [NetworkNode] = []
    /// The 24h window (bounds + density buckets) the scrubber spans.
    public private(set) var window: TimelineWindow
    /// Where the playhead currently sits.
    public private(set) var playhead: Instant
    /// Playing vs paused.
    public private(set) var isPlaying = false
    /// Current playback speed multiplier.
    public private(set) var speed: PlaybackSpeed = .one
    /// Live (tracking now) vs review (scrubbed into the past).
    public private(set) var mode: PlaybackMode = .live

    // MARK: Dependencies

    private let store: MeshStore
    private let clockSource: any Clock
    private let reconstructor: ReplayReconstructor
    private let spanSeconds: Double

    private var observations: [TimelineObservation] = []
    private var positions: [Int64: GeoPoint] = [:]

    public init(
        store: MeshStore,
        clock: any Clock,
        reconstructor: ReplayReconstructor = ReplayReconstructor(),
        spanSeconds: Double = TimelineWindowBuilder.dayInSeconds
    ) {
        self.store = store
        clockSource = clock
        self.reconstructor = reconstructor
        self.spanSeconds = spanSeconds
        let now = clock.now()
        window = TimelineWindowBuilder.build(observations: [], now: now, spanSeconds: spanSeconds)
        playhead = now
    }

    // MARK: Loading

    /// Load node positions + the last 24h of observations from the store and
    /// rebuild the window. Pins the playhead to "now" (live) and refreshes the
    /// derived frame.
    public func load() async throws {
        try await loadNodes()
        let now = clockSource.now()
        let since = now.adding(seconds: -spanSeconds)
        observations = try await store.timelineObservations(since: since, until: now)
        window = TimelineWindowBuilder.build(observations: observations, now: now, spanSeconds: spanSeconds)
        goLive()
    }

    private func loadNodes() async throws {
        var built: [NetworkNode] = []
        var positionMap: [Int64: GeoPoint] = [:]
        for record in try await store.allNodes() {
            let fixes = try await store.positionFixes(forNode: record.node_num)
            guard let latest = fixes.max(by: { $0.t < $1.t }) else { continue }
            let geo = GeoPoint(latitude: latest.lat, longitude: latest.lon)
            positionMap[record.node_num] = geo
            built.append(NetworkNode(
                id: record.node_num,
                name: Self.displayName(record),
                position: geo,
                hopsFromGateway: 0,
                isGateway: record.node_class == .gateway
            ))
        }
        nodes = built
        positions = positionMap
    }

    // MARK: Transport controls

    public func play() {
        isPlaying = true
        if mode == .live { mode = .review } // hitting play from live drops into review
    }

    public func pause() {
        isPlaying = false
    }

    public func togglePlay() {
        isPlaying ? pause() : play()
    }

    public func setSpeed(_ newSpeed: PlaybackSpeed) {
        speed = newSpeed
        refresh()
    }

    /// Scrub the playhead to `fraction` (in [0,1]) across the window. Scrubbing
    /// always enters review mode; reaching the end re-enters live.
    public func scrub(toFraction fraction: Double) {
        seek(to: window.instant(atFraction: fraction))
    }

    /// Move the playhead to an exact instant (clamped to the window).
    public func seek(to instant: Instant) {
        let clamped = clampToWindow(instant)
        playhead = clamped
        mode = clamped >= window.end ? .live : .review
        refresh()
    }

    /// Return to live: pin the playhead to the window end, pause review, and let
    /// the live trace feed take over (the map switches back to NetworkViewModel).
    public func goLive() {
        mode = .live
        isPlaying = false
        playhead = window.end
        refresh()
    }

    // MARK: Animation clock

    /// Advance the playhead by `delta` real seconds scaled by `speed`, while
    /// playing in review. Stops (and returns to live) when it reaches the window
    /// end. The view's display-link / TimelineView drives this each frame.
    public func tick(delta: Double) {
        guard isPlaying, mode == .review, delta > 0 else { return }
        let advanced = playhead.adding(seconds: delta * speed.rawValue)
        if advanced >= window.end {
            goLive()
        } else {
            playhead = advanced
            refresh()
        }
    }

    // MARK: Derivation

    /// Recompute the active traces + clock for the current playhead/speed.
    private func refresh() {
        let frame = reconstructor.frame(
            observations: observations,
            playhead: playhead,
            speed: speed,
            positions: positions
        )
        traces = frame.traces
        clock = frame.clock
    }

    private func clampToWindow(_ instant: Instant) -> Instant {
        if instant < window.start { return window.start }
        if instant > window.end { return window.end }
        return instant
    }

    nonisolated static func displayName(_ record: NodeRecord) -> String {
        record.short_name ?? record.long_name ?? record.hexid
            ?? String(format: "!%08x", UInt32(truncatingIfNeeded: record.node_num))
    }
}
