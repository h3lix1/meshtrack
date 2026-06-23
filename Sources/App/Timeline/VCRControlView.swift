// VCRControlView — the time-travel transport bar for the map (G9, §3).
//
// A bespoke Canvas scrubber (density strip behind a track + a draggable playhead)
// plus play/pause, a speed selector, and a "return to live" button. Built from
// Canvas + simple shapes (not stock sliders/controls) so it snapshots cleanly
// under the headless ImageRenderer gate (cf. memory: stock controls render badly
// headless). It is purely presentational — state in, intents out — so the
// TimelineViewModel owns all logic and the view stays snapshot-deterministic.

import Domain
import SwiftUI

/// The presentational state the control renders. Built from `TimelineViewModel`
/// at integration; standalone here so the view has no MainActor VM dependency and
/// previews/snapshots are deterministic.
public struct VCRControlState: Equatable, Sendable {
    /// Per-bucket observation counts (oldest first) for the density strip.
    public let buckets: [Int]
    /// Playhead position across the track, 0 (start) … 1 (end).
    public let playheadFraction: Double
    public let isPlaying: Bool
    public let isLive: Bool
    public let speed: PlaybackSpeed
    /// Packet id being replayed as a loop, nil for normal timeline playback.
    public let focusedPacketID: UInt32?
    /// Real seconds to wait after a focused packet finishes before restarting.
    public let repeatDelaySeconds: Double
    /// A short label for the playhead time (e.g. "-3h12m", "LIVE").
    public let playheadLabel: String

    public init(
        buckets: [Int],
        playheadFraction: Double,
        isPlaying: Bool,
        isLive: Bool,
        speed: PlaybackSpeed,
        focusedPacketID: UInt32? = nil,
        repeatDelaySeconds: Double = 2,
        playheadLabel: String
    ) {
        self.buckets = buckets
        self.playheadFraction = max(0, min(1, playheadFraction))
        self.isPlaying = isPlaying
        self.isLive = isLive
        self.speed = speed
        self.focusedPacketID = focusedPacketID
        self.repeatDelaySeconds = max(0, repeatDelaySeconds)
        self.playheadLabel = playheadLabel
    }
}

/// The intents the control emits; the host (TimelineViewModel) handles them.
public struct VCRControlActions {
    public var togglePlay: () -> Void
    public var scrub: (Double) -> Void
    public var setSpeed: (PlaybackSpeed) -> Void
    public var setRepeatDelay: (Double) -> Void
    public var goLive: () -> Void
    /// Advance playback by the given real-seconds delta since the last frame. The
    /// view fires this once per frame while playing; the host forwards it to
    /// `TimelineViewModel.tick(delta:)`, which scales by speed and stops at the end.
    public var tick: (Double) -> Void

    public init(
        togglePlay: @escaping () -> Void = {},
        scrub: @escaping (Double) -> Void = { _ in },
        setSpeed: @escaping (PlaybackSpeed) -> Void = { _ in },
        setRepeatDelay: @escaping (Double) -> Void = { _ in },
        goLive: @escaping () -> Void = {},
        tick: @escaping (Double) -> Void = { _ in }
    ) {
        self.togglePlay = togglePlay
        self.scrub = scrub
        self.setSpeed = setSpeed
        self.setRepeatDelay = setRepeatDelay
        self.goLive = goLive
        self.tick = tick
    }
}

public struct VCRControlView: View {
    public let state: VCRControlState
    public let actions: VCRControlActions

    public init(state: VCRControlState, actions: VCRControlActions = VCRControlActions()) {
        self.state = state
        self.actions = actions
    }

    private var accent: Color {
        state.isLive ? .green : .cyan
    }

    public var body: some View {
        HStack(spacing: 14) {
            playPauseButton
            scrubber
            speedSelector
            if state.focusedPacketID != nil {
                repeatDelayControl
            }
            liveButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
        )
        .frame(minWidth: 560)
        .background(playbackDriver)
    }

    /// While playing, a `TimelineView`-backed driver ticks the playhead each frame;
    /// when paused it's absent, so SwiftUI tears down the frame schedule and ticking
    /// stops. Kept out of the snapshot path (zero-size, only present mid-playback).
    @ViewBuilder private var playbackDriver: some View {
        if state.isPlaying {
            PlaybackTickDriver(onTick: actions.tick)
        }
    }

    // MARK: Play / pause

    private var playPauseButton: some View {
        Button(action: actions.togglePlay) {
            Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 34, height: 34)
                .background(accent, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(state.isPlaying ? "Pause" : "Play")
    }

    // MARK: Scrubber (Canvas: density strip + track + playhead)

    private var scrubber: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                drawTrack(&context, size: size)
                drawDensity(&context, size: size)
                drawPlayhead(&context, size: size)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = value.location.x / max(1, geometry.size.width)
                        actions.scrub(max(0, min(1, fraction)))
                    }
            )
        }
        .frame(height: 38)
        .frame(maxWidth: .infinity)
    }

    private func drawTrack(_ context: inout GraphicsContext, size: CGSize) {
        let trackRect = CGRect(x: 0, y: size.height / 2 - 3, width: size.width, height: 6)
        context.fill(
            Path(roundedRect: trackRect, cornerRadius: 3),
            with: .color(.white.opacity(0.10))
        )
        // Filled portion up to the playhead.
        let filled = CGRect(x: 0, y: trackRect.minY, width: size.width * state.playheadFraction, height: 6)
        context.fill(Path(roundedRect: filled, cornerRadius: 3), with: .color(accent.opacity(0.6)))
    }

    private func drawDensity(_ context: inout GraphicsContext, size: CGSize) {
        guard !state.buckets.isEmpty else { return }
        let peak = max(1, state.buckets.max() ?? 1)
        let barWidth = size.width / CGFloat(state.buckets.count)
        let maxBarHeight = size.height / 2 - 5
        for (index, count) in state.buckets.enumerated() {
            guard count > 0 else { continue }
            let height = max(1.5, maxBarHeight * CGFloat(count) / CGFloat(peak))
            let x = CGFloat(index) * barWidth
            let bar = CGRect(
                x: x + 0.5,
                y: size.height / 2 - 5 - height,
                width: max(1, barWidth - 1),
                height: height
            )
            let lit = (CGFloat(index) / CGFloat(state.buckets.count)) <= state.playheadFraction
            context.fill(
                Path(roundedRect: bar, cornerRadius: 1),
                with: .color(accent.opacity(lit ? 0.85 : 0.28))
            )
        }
    }

    private func drawPlayhead(_ context: inout GraphicsContext, size: CGSize) {
        let x = size.width * state.playheadFraction
        var line = Path()
        line.move(to: CGPoint(x: x, y: 2))
        line.addLine(to: CGPoint(x: x, y: size.height - 2))
        context.stroke(line, with: .color(.white.opacity(0.9)), lineWidth: 2)
        let knob = CGRect(x: x - 6, y: size.height / 2 - 6, width: 12, height: 12)
        context.fill(Path(ellipseIn: knob), with: .color(.white))
        context.fill(Path(ellipseIn: knob.insetBy(dx: 3, dy: 3)), with: .color(accent))

        let label = context.resolve(
            Text(state.playheadLabel)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
        )
        let measured = label.measure(in: CGSize(width: 90, height: 16))
        let labelX = min(max(measured.width / 2 + 2, x), size.width - measured.width / 2 - 2)
        context.draw(label, at: CGPoint(x: labelX, y: size.height - 8))
    }

    // MARK: Speed

    private var speedSelector: some View {
        HStack(spacing: 4) {
            ForEach(PlaybackSpeed.allCases, id: \.self) { option in
                Button {
                    actions.setSpeed(option)
                } label: {
                    Text(option.label)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(option == state.speed ? .black : .white.opacity(0.7))
                        .frame(width: 34, height: 26)
                        .background(
                            option == state
                                .speed ? AnyShapeStyle(accent) : AnyShapeStyle(Color.white.opacity(0.07)),
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Speed \(option.label)")
            }
        }
    }

    private var repeatDelayControl: some View {
        HStack(spacing: 5) {
            Button {
                actions.setRepeatDelay(state.repeatDelaySeconds - 0.5)
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Decrease repeat delay")

            VStack(spacing: 1) {
                Text("LOOP")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                Text(String(format: "%.1fs", state.repeatDelaySeconds))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.82))
                    .frame(width: 42)
            }

            Button {
                actions.setRepeatDelay(state.repeatDelaySeconds + 0.5)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Increase repeat delay")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
    }

    // MARK: Return to live

    private var liveButton: some View {
        Button(action: actions.goLive) {
            HStack(spacing: 6) {
                Circle().fill(state.isLive ? .green : .secondary).frame(width: 7, height: 7)
                Text("LIVE").font(.system(size: 11, weight: .bold)).tracking(1)
            }
            .foregroundStyle(state.isLive ? .green : .white.opacity(0.75))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.white.opacity(0.07), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(state.isLive)
        .accessibilityLabel("Return to live")
    }
}

#if DEBUG
    #Preview("VCR control — reviewing") {
        VCRControlView(
            state: VCRControlState(
                buckets: VCRControlState.previewBuckets,
                playheadFraction: 0.62,
                isPlaying: true,
                isLive: false,
                speed: .two,
                playheadLabel: "-9h08m"
            )
        )
        .padding(40)
        .frame(width: 760)
        .background(Color(red: 0.03, green: 0.04, blue: 0.10))
    }

    #Preview("VCR control — live") {
        VCRControlView(
            state: VCRControlState(
                buckets: VCRControlState.previewBuckets,
                playheadFraction: 1,
                isPlaying: false,
                isLive: true,
                speed: .one,
                playheadLabel: "LIVE"
            )
        )
        .padding(40)
        .frame(width: 760)
        .background(Color(red: 0.03, green: 0.04, blue: 0.10))
    }

    extension VCRControlState {
        /// A plausible 24h density profile for previews/snapshots (busier by day).
        static let previewBuckets: [Int] = (0 ..< 96).map { index in
            let hour = Double(index) / 4
            let daylight = max(0, sin((hour - 6) / 24 * 2 * .pi))
            return Int(2 + daylight * 30 + (index % 5 == 0 ? 6 : 0))
        }
    }
#endif
