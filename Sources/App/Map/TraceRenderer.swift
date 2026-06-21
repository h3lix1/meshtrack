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

/// Stateless drawing for traces + node glows over any `TraceProjection`.
@MainActor
public struct TraceRenderer {
    public var clock: Double
    public var hopDuration: Double
    public var mode: TraceTimingMode

    public init(clock: Double, hopDuration: Double, mode: TraceTimingMode) {
        self.clock = clock
        self.hopDuration = hopDuration
        self.mode = mode
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

    private func progress(_ trace: PacketTrace, _ edgeIndex: Int) -> Double {
        TraceTiming.edgeProgress(
            clock: clock,
            startedAt: trace.startedAt,
            edgeIndex: edgeIndex,
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
        for (index, edge) in trace.edges.enumerated() {
            let fraction = progress(trace, index)
            guard fraction > 0 else { continue }
            let start = projection.point(for: edge.from)
            let end = projection.point(for: edge.to)
            let tip = TraceTiming.lerp(start, end, fraction)

            var line = Path()
            line.move(to: start)
            line.addLine(to: tip)
            let dash: [CGFloat] = edge.kind == .guessed ? [7, 6] : []

            // Drawn portion (source → tip): a soft glow under a crisp core. The line
            // grows from the source toward the gateway as `fraction` advances, so the
            // packet visibly travels along the hop (Task 2).
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 7))
                layer.stroke(
                    line,
                    with: .color(color.opacity(0.6)),
                    style: StrokeStyle(lineWidth: 7, lineCap: .round, dash: dash)
                )
            }
            // A trailing fade behind the moving head: the line is brightest at the tip
            // (the "comet" head) and fades back toward the source.
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

            // The moving spark head: a bright blurred halo + a hot white core that
            // rides the tip while the edge is still drawing.
            if fraction < 1, let head = TraceTiming.headPoint(from: start, to: end, progress: fraction) {
                drawSparkHead(at: head, color: color, in: &context)
            }
        }
        if let badge = badgePoint(trace, projection: projection) {
            drawBadge(
                "\(trace.hops)\u{2009}hop\(trace.hops == 1 ? "" : "s")",
                at: badge,
                color: color,
                in: context
            )
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
        for index in stride(from: trace.edges.count - 1, through: 0, by: -1) {
            let fraction = progress(trace, index)
            guard fraction > 0 else { continue }
            let edge = trace.edges[index]
            return TraceTiming.lerp(
                projection.point(for: edge.from),
                projection.point(for: edge.to),
                fraction
            )
        }
        return nil
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

    // MARK: Nodes

    public func drawNodes(
        _ nodes: [NetworkNode],
        in context: inout GraphicsContext,
        projection: some TraceProjection
    ) {
        for node in nodes {
            drawNode(node, in: &context, projection: projection)
        }
    }

    private func drawNode(
        _ node: NetworkNode,
        in context: inout GraphicsContext,
        projection: some TraceProjection
    ) {
        let center = projection.point(for: node.position)
        let color = Self.nodeColor(node)
        let coreRadius: CGFloat = node.isGateway ? 9 : 6

        context.drawLayer { layer in
            layer.addFilter(.blur(radius: node.isGateway ? 16 : 10))
            layer.fill(circle(at: center, radius: 16), with: .color(color.opacity(0.6)))
        }
        if node.isGateway {
            context.stroke(circle(at: center, radius: 15), with: .color(color.opacity(0.85)), lineWidth: 1.5)
        }
        context.fill(circle(at: center, radius: coreRadius), with: .color(.white))
        context.fill(circle(at: center, radius: coreRadius - 2), with: .color(color))

        if let battery = node.batteryPercent {
            let batteryColor: Color = battery < 20 ? .red : (battery < 50 ? .yellow : .green)
            var arc = Path()
            arc.addArc(
                center: center,
                radius: coreRadius + 5,
                startAngle: .degrees(-90),
                endAngle: .degrees(-90 + 360 * battery / 100),
                clockwise: false
            )
            context.stroke(arc, with: .color(batteryColor.opacity(0.9)), lineWidth: 2)
        }

        let label = context.resolve(
            Text(node.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
        )
        context.draw(label, at: CGPoint(x: center.x, y: center.y + coreRadius + 15))
    }

    static func nodeColor(_ node: NetworkNode) -> Color {
        if node.isGateway { return Color(red: 0.3, green: 0.95, blue: 1.0) }
        switch node.hopsFromGateway {
        case 0, 1: return Color(red: 0.45, green: 0.85, blue: 1.0)
        case 2: return Color(red: 0.6, green: 0.7, blue: 1.0)
        default: return Color(red: 0.75, green: 0.6, blue: 1.0)
        }
    }

    private func circle(at center: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
    }
}
