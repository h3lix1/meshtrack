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
    /// Packet id currently replaying as a deterministic loop, nil for normal timeline playback.
    public private(set) var focusedPacketID: UInt32?
    /// Relay-byte ambiguity policy used for normal replay and focused packet loops.
    public private(set) var relayGuessing: RelayGuessingPolicy = .nearestCandidate

    /// Real seconds to pause after a focused packet's animation finishes before it restarts.
    public var packetRepeatDelaySeconds: Double {
        get { storedPacketRepeatDelaySeconds }
        set { storedPacketRepeatDelaySeconds = Self.clampRepeatDelay(newValue) }
    }

    public static let minPacketRepeatDelaySeconds: Double = 0
    public static let maxPacketRepeatDelaySeconds: Double = 10

    /// True when the playhead is scrubbed off "live" into the past (item 1). When this
    /// flips true the map should feed from this VM's reconstructed `traces`/`nodes`
    /// instead of the live coordinator's; when it flips back false the live feed takes
    /// over again. The lead reads this in `LiveRootView` to switch the source.
    public var isReviewing: Bool {
        mode == .review
    }

    // MARK: Dependencies

    private let store: MeshStore
    private let clockSource: any Clock
    private let reconstructor: ReplayReconstructor
    private let spanSeconds: Double

    private var observations: [TimelineObservation] = []
    private var positions: [Int64: GeoPoint] = [:]
    /// CLIENT_MUTE nodes — never rebroadcast, so they are excluded from relay-byte guesses
    /// during reconstruction (they can only be the source or addressed destination).
    private var nonRelayNodes: Set<Int64> = []
    private var focusedLoopElapsedSeconds: Double = 0
    private var storedPacketRepeatDelaySeconds: Double = 2
    private let focusedReplayHopDurationSeconds: Double = 1.2
    private let focusedReplayTimingMode: TraceTimingMode = .sequential

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
        var muteNodes: Set<Int64> = []
        for record in try await store.allNodes() {
            if NodeRole.isNonRelaying(rawRole: record.role) { muteNodes.insert(record.node_num) }
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
        nonRelayNodes = muteNodes
    }

    // MARK: Transport controls

    public func play() {
        if focusedPacketID != nil {
            guard focusedPacketCanReplay() else {
                isPlaying = false
                return
            }
            mode = .review
            isPlaying = true
            refresh()
            return
        }
        isPlaying = true
        if mode == .live {
            // Hitting play from live drops into review. The playhead is pinned at
            // window.end, though, so the first tick(delta>0) would see it already at
            // the end and snap straight back to live (a no-op bounce). Rewind to the
            // window start so review playback actually runs forward from the edge.
            mode = .review
            playhead = window.start
            refresh()
        }
    }

    public func pause() {
        isPlaying = false
    }

    public func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    public func setSpeed(_ newSpeed: PlaybackSpeed) {
        speed = newSpeed
        refresh()
    }

    public func setRelayGuessingPolicy(_ policy: RelayGuessingPolicy) {
        guard relayGuessing != policy else { return }
        relayGuessing = policy
        refresh()
    }

    /// Scrub the playhead to `fraction` (in [0,1]) across the window. Scrubbing
    /// always enters review mode; reaching the end re-enters live.
    public func scrub(toFraction fraction: Double) {
        focusedPacketID = nil
        seek(to: window.instant(atFraction: fraction))
    }

    /// Move the playhead to an exact instant (clamped to the window).
    public func seek(to instant: Instant) {
        focusedPacketID = nil
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
        focusedPacketID = nil
        focusedLoopElapsedSeconds = 0
        playhead = window.end
        refresh()
    }

    // MARK: Animation clock

    /// Advance the playhead by `delta` real seconds scaled by `speed`, while
    /// playing in review. Stops (and returns to live) when it reaches the window
    /// end. The view's display-link / TimelineView drives this each frame.
    public func tick(delta: Double) {
        guard isPlaying, mode == .review, delta > 0 else { return }
        if focusedPacketID != nil {
            tickFocusedPacket(delta: delta)
            return
        }
        let advanced = playhead.adding(seconds: delta * speed.rawValue)
        if advanced >= window.end {
            goLive()
        } else {
            playhead = advanced
            refresh()
        }
    }

    // MARK: View bridge

    /// The presentational state the VCRControlView renders. Lets the lead wire
    /// `VCRControlView(state: vm.controlState, actions: .init(...))` with no glue.
    public var controlState: VCRControlState {
        VCRControlState(
            buckets: window.buckets,
            playheadFraction: window.fraction(of: playhead),
            isPlaying: isPlaying,
            isLive: mode == .live,
            speed: speed,
            focusedPacketID: focusedPacketID,
            repeatDelaySeconds: packetRepeatDelaySeconds,
            playheadLabel: playheadLabel
        )
    }

    /// A short "time-ago" label for the playhead ("LIVE" at the window end).
    public var playheadLabel: String {
        if let focusedPacketID {
            return "PKT " + NodeID.hex(focusedPacketID).replacingOccurrences(of: "!", with: "#")
        }
        if mode == .live { return "LIVE" }
        let secondsAgo = max(0, window.end.secondsSince(playhead))
        let hours = Int(secondsAgo) / 3600
        let minutes = (Int(secondsAgo) % 3600) / 60
        return hours > 0 ? "-\(hours)h\(String(format: "%02d", minutes))m" : "-\(minutes)m"
    }

    // MARK: Derivation

    /// Recompute the active traces + clock for the current playhead/speed.
    private func refresh() {
        if let focusedPacketID {
            let frame = focusedReplayFrame(packetID: focusedPacketID)
            traces = frame.traces
            clock = frame.clock
            return
        }
        let frame = reconstructor.frame(
            observations: observations,
            playhead: playhead,
            speed: speed,
            positions: positions,
            relayGuessing: relayGuessing,
            nonRelayNodes: nonRelayNodes
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
            ?? NodeID.hex(UInt32(truncatingIfNeeded: record.node_num))
    }
}

public extension TimelineViewModel {
    @discardableResult
    func focusPacket(_ packetID: UInt32?, autoplay: Bool = false) -> Bool {
        guard let packetID else {
            focusedPacketID = nil
            focusedLoopElapsedSeconds = 0
            refresh()
            return true
        }
        guard packetCanReplay(packetID) else {
            focusedPacketID = nil
            focusedLoopElapsedSeconds = 0
            isPlaying = false
            refresh()
            return false
        }
        focusedPacketID = packetID
        focusedLoopElapsedSeconds = 0
        mode = .review
        playhead = firstObservationTime(for: packetID) ?? playhead
        isPlaying = autoplay
        refresh()
        return true
    }

    @discardableResult
    func reloadAndFocusPacket(_ packetID: UInt32?, autoplay: Bool = true) async throws -> Bool {
        try await reloadHistory()
        return focusPacket(packetID, autoplay: autoplay)
    }
}

private extension TimelineViewModel {
    static func clampRepeatDelay(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return minPacketRepeatDelaySeconds }
        return min(maxPacketRepeatDelaySeconds, max(minPacketRepeatDelaySeconds, seconds))
    }

    func reloadHistory() async throws {
        let now = clockSource.now()
        let since = now.adding(seconds: -spanSeconds)
        observations = try await store.timelineObservations(since: since, until: now)
        window = TimelineWindowBuilder.build(observations: observations, now: now, spanSeconds: spanSeconds)
    }

    func tickFocusedPacket(delta: Double) {
        guard let packetID = focusedPacketID, packetCanReplay(packetID) else {
            isPlaying = false
            return
        }
        let animationDuration = focusedAnimationDuration(packetID: packetID)
        guard animationDuration > 0 else {
            isPlaying = false
            return
        }
        let animationRealSeconds = animationDuration / max(speed.rawValue, .leastNonzeroMagnitude)
        let loopDuration = animationRealSeconds + packetRepeatDelaySeconds
        guard loopDuration > 0 else {
            focusedLoopElapsedSeconds = 0
            refresh()
            return
        }

        focusedLoopElapsedSeconds += delta
        while focusedLoopElapsedSeconds >= loopDuration {
            focusedLoopElapsedSeconds -= loopDuration
        }
        playhead = firstObservationTime(for: packetID)?
            .adding(seconds: focusedReplayClock(packetID: packetID))
            ?? playhead
        refresh()
    }

    func focusedReplayFrame(packetID: UInt32) -> ReplayFrame {
        reconstructor.focusedPacketFrame(
            observations: observations,
            packetID: packetID,
            clock: focusedReplayClock(packetID: packetID),
            positions: positions,
            relayGuessing: relayGuessing,
            nonRelayNodes: nonRelayNodes
        )
    }

    func focusedReplayClock(packetID: UInt32) -> Double {
        let duration = focusedAnimationDuration(packetID: packetID)
        guard duration > 0 else { return 0 }
        let animationRealSeconds = duration / max(speed.rawValue, .leastNonzeroMagnitude)
        if focusedLoopElapsedSeconds >= animationRealSeconds {
            return duration
        }
        return min(duration, focusedLoopElapsedSeconds * speed.rawValue)
    }

    func focusedAnimationDuration(packetID: UInt32) -> Double {
        let frame = reconstructor.focusedPacketFrame(
            observations: observations,
            packetID: packetID,
            clock: 0,
            positions: positions,
            relayGuessing: relayGuessing,
            nonRelayNodes: nonRelayNodes
        )
        // Use the packet's true hop count, not just the drawn edge indices: an
        // undecomposable multi-hop path is drawn as a single first-hop segment (so the
        // source never appears to re-send), yet its replay should still run for the full
        // hop count rather than collapse to one hop.
        let maxHop = frame.traces.map { max($0.maxHopIndex, $0.hops) }.max() ?? 0
        return TraceTiming.journeyDuration(
            edgeCount: maxHop,
            hopDuration: focusedReplayHopDurationSeconds,
            mode: focusedReplayTimingMode
        )
    }

    func focusedPacketCanReplay() -> Bool {
        focusedPacketID.map(packetCanReplay) ?? false
    }

    func packetCanReplay(_ packetID: UInt32) -> Bool {
        !focusedReplayFrame(packetID: packetID).traces.isEmpty
    }

    func firstObservationTime(for packetID: UInt32) -> Instant? {
        observations
            .filter { $0.packetID == packetID }
            .map(\.rxTime)
            .min()
    }
}
