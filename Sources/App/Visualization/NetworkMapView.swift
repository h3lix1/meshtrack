// NetworkMapView — the live network visualization. A Canvas renders glowing nodes
// at their geographic positions and animates packet traces along their hops, with
// hop-normalised draw speed (shorter hops draw slower so every hop finishes
// together), a distinct colour per packet id, a moving head spark, and a hop-count
// badge. `clock` is the animation time in seconds; `hopDuration` configures it.

import Domain
import SwiftUI

public struct NetworkMapView: View {
    public let nodes: [NetworkNode]
    public let traces: [PacketTrace]
    public var clock: Double
    public var hopDuration: Double

    public init(nodes: [NetworkNode], traces: [PacketTrace], clock: Double = 1e9, hopDuration: Double = 1.2) {
        self.nodes = nodes
        self.traces = traces
        self.clock = clock
        self.hopDuration = hopDuration
    }

    public var body: some View {
        Canvas { context, size in
            let inset = CGRect(origin: .zero, size: size).insetBy(dx: 90, dy: 90)
            let projection = GeoProjection(points: nodes.map(\.position), in: inset)
            drawGrid(context, size: size)
            for trace in traces {
                drawTrace(trace, in: &context, projection: projection)
            }
            for node in nodes {
                drawNode(node, in: &context, projection: projection)
            }
        }
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.02, green: 0.03, blue: 0.09),
                    Color(red: 0.04, green: 0.06, blue: 0.17)
                ],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    private func drawGrid(_ context: GraphicsContext, size: CGSize) {
        var grid = Path()
        let step: CGFloat = 80
        for x in stride(from: 0, to: size.width, by: step) {
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        for y in stride(from: 0, to: size.height, by: step) {
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(grid, with: .color(.white.opacity(0.04)), lineWidth: 0.5)
    }

    // MARK: Traces

    /// Progress for edges at hop number `hopIndex` (1-based), so every edge of a hop
    /// reveals together as the wavefront expands ring-by-ring (item 2).
    private func edgeProgress(_ trace: PacketTrace, _ hopIndex: Int) -> Double {
        let elapsed = clock - trace.startedAt - Double(max(0, hopIndex - 1)) * hopDuration
        return min(1, max(0, elapsed / hopDuration))
    }

    private func drawTrace(
        _ trace: PacketTrace,
        in context: inout GraphicsContext,
        projection: GeoProjection
    ) {
        let color = trace.color
        for edge in trace.edges {
            let progress = edgeProgress(trace, edge.hopIndex)
            guard progress > 0 else { continue }
            let start = projection.point(for: edge.from)
            let end = projection.point(for: edge.to)
            let tip = lerp(start, end, progress)

            var line = Path()
            line.move(to: start)
            line.addLine(to: tip)
            let dash: [CGFloat] = edge.kind == .guessed ? [7, 6] : []

            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 7))
                layer.stroke(
                    line,
                    with: .color(color.opacity(0.6)),
                    style: StrokeStyle(lineWidth: 7, lineCap: .round, dash: dash)
                )
            }
            context.stroke(
                line,
                with: .color(color),
                style: StrokeStyle(
                    lineWidth: edge.kind == .guessed ? 1.6 : 2.8,
                    lineCap: .round,
                    dash: dash
                )
            )

            if progress < 1 {
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: 4))
                    layer.fill(circle(at: tip, radius: 5), with: .color(.white))
                }
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

    private func badgePoint(_ trace: PacketTrace, projection: GeoProjection) -> CGPoint? {
        for edge in trace.edges.reversed() {
            let progress = edgeProgress(trace, edge.hopIndex)
            guard progress > 0 else { continue }
            return lerp(projection.point(for: edge.from), projection.point(for: edge.to), progress)
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

    // MARK: Nodes

    private func drawNode(_ node: NetworkNode, in context: inout GraphicsContext, projection: GeoProjection) {
        let center = projection.point(for: node.position)
        let color = nodeColor(node)
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

        let label = context.resolve(Text(node.name).font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.92)))
        context.draw(label, at: CGPoint(x: center.x, y: center.y + coreRadius + 15))
    }

    private func nodeColor(_ node: NetworkNode) -> Color {
        if node.isGateway { return Color(red: 0.3, green: 0.95, blue: 1.0) }
        switch node.hopsFromGateway {
        case 0, 1: return Color(red: 0.45, green: 0.85, blue: 1.0)
        case 2: return Color(red: 0.6, green: 0.7, blue: 1.0)
        default: return Color(red: 0.75, green: 0.6, blue: 1.0)
        }
    }

    private func lerp(_ from: CGPoint, _ to: CGPoint, _ fraction: Double) -> CGPoint {
        CGPoint(x: from.x + (to.x - from.x) * fraction, y: from.y + (to.y - from.y) * fraction)
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
