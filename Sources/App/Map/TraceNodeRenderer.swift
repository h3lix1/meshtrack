// TraceNodeRenderer — the node-glow drawing for TraceRenderer, split out so the
// renderer's type body stays within the lint cap. Same projection-agnostic Canvas
// drawing (ADR 0007): a soft glow, a white core, an optional battery arc, and the
// node label, coloured by gateway status / hop distance.

import Domain
import SwiftUI

@MainActor
extension TraceRenderer {
    // MARK: Nodes

    public func drawNodes(
        _ nodes: [NetworkNode],
        in context: inout GraphicsContext,
        projection: some TraceProjection,
        cullingBounds: CGRect? = nil
    ) {
        for node in nodes {
            drawNode(node, in: &context, projection: projection, cullingBounds: cullingBounds)
        }
    }

    private func drawNode(
        _ node: NetworkNode,
        in context: inout GraphicsContext,
        projection: some TraceProjection,
        cullingBounds: CGRect? = nil
    ) {
        let center = projection.point(for: node.position)
        // Skip an off-screen node entirely — its glow, core, battery arc and label —
        // when culling is opted in (cullingBounds != nil).
        if let bounds = cullingBounds,
           !Self.isPointVisible(center, in: bounds, margin: Self.cullingMargin) {
            return
        }
        let color = Self.nodeColor(node)
        let coreRadius: CGFloat = node.isGateway ? 9 : 6

        if detail == .interactive {
            context.fill(circle(at: center, radius: coreRadius), with: .color(color.opacity(0.88)))
            return
        }

        context.drawLayer { layer in
            layer.addFilter(.blur(radius: node.isGateway ? 16 : 10))
            layer.fill(circle(at: center, radius: 16), with: .color(color.opacity(0.6)))
        }
        if node.isGateway {
            context.stroke(circle(at: center, radius: 15), with: .color(color.opacity(0.85)), lineWidth: 1.5)
        }
        context.fill(circle(at: center, radius: coreRadius), with: .color(.white))
        context.fill(circle(at: center, radius: coreRadius - 2), with: .color(color))
        drawBatteryArc(node, center: center, coreRadius: coreRadius, in: context)

        let label = context.resolve(
            Text(node.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
        )
        context.draw(label, at: CGPoint(x: center.x, y: center.y + coreRadius + 15))
    }

    private func drawBatteryArc(
        _ node: NetworkNode, center: CGPoint, coreRadius: CGFloat, in context: GraphicsContext
    ) {
        guard let battery = node.batteryPercent else { return }
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

    static func nodeColor(_ node: NetworkNode) -> Color {
        if node.isGateway { return Color(red: 0.3, green: 0.95, blue: 1.0) }
        switch node.hopsFromGateway {
        case 0, 1: return Color(red: 0.45, green: 0.85, blue: 1.0)
        case 2: return Color(red: 0.6, green: 0.7, blue: 1.0)
        default: return Color(red: 0.75, green: 0.6, blue: 1.0)
        }
    }
}
