// TraceRenderer — the shared Canvas drawing for animated packet traces, node glows,
// hop badges and latency tooltips (SPEC §1.5/1.6). It is deliberately
// projection-agnostic: it draws through a `TraceProjection`, so the SAME code paints
// onto the live MapKit overlay (`MapProjection`, backed by MKMapView.convert) and
// onto the headless Canvas snapshot (`GeoProjection`, backed by a rect) — ADR 0007.
//
// The per-edge timing comes from `TraceTiming` (sequential vs equalise-finish), the
// per-id colour from `PacketColor`, and the styling (guessed=dashed/thin,
// observed=solid) matches the existing `NetworkMapView` so the two renderers read
// identically. No MapKit import here; only SwiftUI's GraphicsContext.

import Domain
import SwiftUI

public enum TraceRenderDetail: Sendable, Equatable {
    case full
    case interactive
}

/// Stateless drawing for traces + node glows over any `TraceProjection`.
@MainActor
public struct TraceRenderer {
    public var clock: Double
    public var hopDuration: Double
    public var mode: TraceTimingMode
    /// The packet id currently focused in the legend, or nil. Per-hop labels (item 3)
    /// and the all-receivers overlay (item 6) only draw for the focused packet.
    public var focusedPacketID: UInt32?
    /// Whether to mark every node that received the focused packet (item 6).
    public var showAllReceivers: Bool
    /// Full detail when the map is settled; lightweight strokes during pan/zoom.
    public var detail: TraceRenderDetail

    public init(
        clock: Double,
        hopDuration: Double,
        mode: TraceTimingMode,
        focusedPacketID: UInt32? = nil,
        showAllReceivers: Bool = false,
        detail: TraceRenderDetail = .full
    ) {
        self.clock = clock
        self.hopDuration = hopDuration
        self.mode = mode
        self.focusedPacketID = focusedPacketID
        self.showAllReceivers = showAllReceivers
        self.detail = detail
    }

    private func isFocused(_ id: UInt32) -> Bool {
        focusedPacketID == id
    }

    // MARK: Traces

    public func drawTraces(
        _ traces: [PacketTrace],
        in context: inout GraphicsContext,
        projection: some TraceProjection
    ) {
        for trace in traces {
            drawTrace(trace, in: &context, projection: projection)
        }
    }

    private func progress(_ trace: PacketTrace, _ edge: TraceEdge) -> Double {
        TraceTiming.edgeProgress(
            clock: clock,
            startedAt: trace.startedAt,
            hopIndex: edge.hopIndex,
            hopDuration: hopDuration,
            mode: mode
        )
    }

    private func drawTrace(
        _ trace: PacketTrace,
        in context: inout GraphicsContext,
        projection: some TraceProjection
    ) {
        let color = trace.color
        let focused = isFocused(trace.id)
        for edge in trace.edges {
            let fraction = progress(trace, edge)
            guard fraction > 0 else { continue }
            let segment = Segment(
                start: projection.point(for: edge.from),
                end: projection.point(for: edge.to),
                fraction: fraction
            )
            drawEdge(edge, segment: segment, color: color, in: &context)
            // When this packet is focused, label EACH hop with its hop number along the
            // path (item 3) — not just the final/max hop badge below.
            if detail == .full, focused, fraction > 0.35 {
                let mid = TraceTiming.lerp(segment.start, segment.end, min(fraction, 0.5))
                drawHopTick(edge.hopIndex, at: mid, color: color, in: context)
            }
        }
        // When focused + the toggle is on, mark every node that received this packet,
        // annotated with the hop at which it heard it (item 6).
        if detail == .full, focused, showAllReceivers {
            drawReceivers(trace, in: &context, projection: projection)
        }
        if detail == .full, let badge = badgePoint(trace, projection: projection) {
            drawBadge(
                "\(trace.hops)\u{2009}hop\(trace.hops == 1 ? "" : "s")",
                at: badge,
                color: color,
                in: context
            )
        }
    }

    /// A trace edge projected to screen space, with how far along it has drawn.
    private struct Segment {
        let start: CGPoint
        let end: CGPoint
        let fraction: Double
    }

    /// Draw one animated edge: glow, comet trail, and spark head at the moving tip.
    private func drawEdge(
        _ edge: TraceEdge, segment: Segment, color: Color, in context: inout GraphicsContext
    ) {
        let start = segment.start
        let end = segment.end
        let fraction = segment.fraction
        let tip = TraceTiming.lerp(start, end, fraction)
        var line = Path()
        line.move(to: start)
        line.addLine(to: tip)
        let dash: [CGFloat] = edge.kind == .guessed ? [7, 6] : []

        if detail == .interactive {
            context.stroke(
                line,
                with: .color(color.opacity(0.82)),
                style: StrokeStyle(
                    lineWidth: edge.kind == .guessed ? 1.2 : 2.0,
                    lineCap: .round,
                    dash: dash
                )
            )
            return
        }

        // Drawn portion (source → tip): a soft glow under a crisp core. The line grows
        // from the source toward the gateway as `fraction` advances (item 2).
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 7))
            layer.stroke(
                line,
                with: .color(color.opacity(0.6)),
                style: StrokeStyle(lineWidth: 7, lineCap: .round, dash: dash)
            )
        }
        // A trailing fade behind the moving head: brightest at the tip (the "comet"
        // head), fading back toward the source.
        context.stroke(
            line,
            with: .linearGradient(
                Gradient(colors: [color.opacity(0.25), color]),
                startPoint: start,
                endPoint: tip
            ),
            style: StrokeStyle(
                lineWidth: edge.kind == .guessed ? 1.6 : 2.8,
                lineCap: .round,
                dash: dash
            )
        )
        if fraction < 1, let head = TraceTiming.headPoint(from: start, to: end, progress: fraction) {
            drawSparkHead(at: head, color: color, in: &context)
        }
    }

    /// The moving "spark" at the head of a still-drawing edge: a coloured halo with a
    /// hot white core (Task 2).
    private func drawSparkHead(at head: CGPoint, color: Color, in context: inout GraphicsContext) {
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 6))
            layer.fill(circle(at: head, radius: 7), with: .color(color))
        }
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 2))
            layer.fill(circle(at: head, radius: 3.5), with: .color(.white))
        }
    }

    /// The point where the hop badge rides: the head of the furthest-along started edge.
    private func badgePoint(_ trace: PacketTrace, projection: some TraceProjection) -> CGPoint? {
        for edge in trace.edges.reversed() {
            let fraction = progress(trace, edge)
            guard fraction > 0 else { continue }
            return TraceTiming.lerp(
                projection.point(for: edge.from),
                projection.point(for: edge.to),
                fraction
            )
        }
        return nil
    }

    // MARK: Per-hop labels + receivers (focus mode)

    /// A small "n" hop chip drawn at an edge midpoint when a packet is focused (item 3),
    /// so the operator reads hop 1, 2, 3 … along the path rather than only the final hop.
    private func drawHopTick(_ hop: Int, at point: CGPoint, color: Color, in context: GraphicsContext) {
        let radius: CGFloat = 8
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        context.fill(circle(at: point, radius: radius), with: .color(.black.opacity(0.75)))
        context.stroke(circle(at: point, radius: radius), with: .color(color), lineWidth: 1.5)
        let label = context.resolve(
            Text("\(hop)").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
        )
        context.draw(label, at: CGPoint(x: rect.midX, y: rect.midY))
    }

    /// Mark every node we have evidence received the focused packet — gateways, guessed
    /// relays, and the addressed destination — each ringed and tagged with its reception
    /// hop (item 6/8). The destination is styled distinctly (item 8). Only the rings whose
    /// hop the wavefront has already reached are shown, so they appear in step with the
    /// expanding animation. (Receivers without a known position can't be drawn — those are
    /// listed textually in the legend instead, see VizLegend.receivedBy.)
    private func drawReceivers(
        _ trace: PacketTrace,
        in context: inout GraphicsContext,
        projection: some TraceProjection
    ) {
        for receiver in trace.receivers {
            // Reveal a receiver once the wavefront has reached its hop ring.
            let reached = TraceTiming.edgeProgress(
                clock: clock, startedAt: trace.startedAt, hopIndex: receiver.hop,
                hopDuration: hopDuration, mode: mode
            )
            guard reached > 0 else { continue }
            drawReceiverRing(receiver, color: trace.color, projection: projection, in: &context)
        }
    }

    /// Draw one receiver's ring + hop tick. The destination gets a distinct double-ring +
    /// solid emphasis so the operator reads it as the addressed last-hop recipient (item 8);
    /// gateways get a solid ring, guessed relays a dashed one.
    private func drawReceiverRing(
        _ receiver: TraceReceiver,
        color: Color,
        projection: some TraceProjection,
        in context: inout GraphicsContext
    ) {
        let center = projection.point(for: receiver.position)
        let ringRadius: CGFloat = receiver.isDestination ? 16 : (receiver.isGateway ? 14 : 11)
        let dash: [CGFloat] = receiver.kind == .relay ? [3, 3] : []
        context.stroke(
            circle(at: center, radius: ringRadius),
            with: .color(color.opacity(0.9)),
            style: StrokeStyle(lineWidth: receiver.isDestination ? 3 : 2, dash: dash)
        )
        if receiver.isDestination {
            // A second inner ring marks the addressed final recipient apart from gateways.
            context.stroke(circle(at: center, radius: ringRadius - 4), with: .color(color), lineWidth: 1.5)
        }
        drawHopTick(
            receiver.hop,
            at: CGPoint(x: center.x, y: center.y - ringRadius - 8),
            color: color,
            in: context
        )
    }

    private func drawBadge(_ text: String, at point: CGPoint, color: Color, in context: GraphicsContext) {
        let resolved = context
            .resolve(Text(text).font(.system(size: 10, weight: .bold)).foregroundStyle(.black))
        let size = resolved.measure(in: CGSize(width: 120, height: 40))
        let pad: CGFloat = 5
        let rect = CGRect(
            x: point.x + 9,
            y: point.y - size.height / 2 - pad,
            width: size.width + pad * 2,
            height: size.height + pad * 2
        )
        context.fill(Path(roundedRect: rect, cornerRadius: 6), with: .color(color))
        context.draw(resolved, at: CGPoint(x: rect.midX, y: rect.midY))
    }

    // MARK: Latency tooltip

    /// Draw a small latency tooltip (e.g. "+182 ms") near a trace's badge head. Only
    /// rendered when a latency is supplied for that packet id.
    public func drawLatencyTooltip(
        _ trace: PacketTrace,
        latencyMillis: Int,
        in context: inout GraphicsContext,
        projection: some TraceProjection
    ) {
        guard let head = badgePoint(trace, projection: projection) else { return }
        let text = "+\(latencyMillis)\u{2009}ms"
        let resolved = context.resolve(
            Text(text).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.95))
        )
        let size = resolved.measure(in: CGSize(width: 120, height: 30))
        let pad: CGFloat = 4
        let rect = CGRect(
            x: head.x + 9,
            y: head.y + 8,
            width: size.width + pad * 2,
            height: size.height + pad * 2
        )
        context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(.black.opacity(0.55)))
        context.draw(resolved, at: CGPoint(x: rect.midX, y: rect.midY))
    }

    func circle(at center: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
    }
}
