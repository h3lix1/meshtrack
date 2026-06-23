// TraceRenderer+Receivers — focused-packet receiver rings and observer fan-out spokes.

import Domain
import SwiftUI

@MainActor
extension TraceRenderer {
    /// Mark every node we have evidence received the focused packet — gateways, guessed
    /// relays, and the addressed destination — each ringed and tagged with its reception
    /// hop (item 6/8). The destination is styled distinctly (item 8). Only the rings whose
    /// hop the wavefront has already reached are shown, so they appear in step with the
    /// expanding animation. (Receivers without a known position can't be drawn — those are
    /// listed textually in the legend instead, see VizLegend.receivedBy.)
    func drawReceivers(
        _ trace: PacketTrace,
        in context: inout GraphicsContext,
        projection: some TraceProjection
    ) {
        let fanoutByReceiver = Dictionary(
            uniqueKeysWithValues: ReceiverFanout.segments(for: trace).map { ($0.receiver.nodeID, $0) }
        )
        for receiver in trace.receivers {
            // Reveal a receiver once the wavefront has reached its hop ring.
            let reached = TraceTiming.edgeProgress(
                clock: clock, startedAt: trace.startedAt, hopIndex: receiver.hop,
                hopDuration: hopDuration, mode: mode
            )
            guard reached > 0 else { continue }
            if let segment = fanoutByReceiver[receiver.nodeID] {
                drawReceiverFanout(
                    segment,
                    progress: reached,
                    color: trace.color,
                    projection: projection,
                    in: &context
                )
            }
            drawReceiverRing(receiver, color: trace.color, projection: projection, in: &context)
        }
    }

    private func drawReceiverFanout(
        _ segment: ReceiverFanoutSegment,
        progress: Double,
        color: Color,
        projection: some TraceProjection,
        in context: inout GraphicsContext
    ) {
        let start = projection.point(for: segment.from)
        let end = projection.point(for: segment.receiver.position)
        let tip = TraceTiming.lerp(start, end, min(1, max(0, progress)))
        var path = Path()
        path.move(to: start)
        path.addLine(to: tip)
        let dash: [CGFloat] = segment.receiver.isDestination ? [] : [4, 5]
        context.stroke(
            path,
            with: .color(color.opacity(segment.receiver.isDestination ? 0.8 : 0.55)),
            style: StrokeStyle(
                lineWidth: segment.receiver.isDestination ? 2.2 : 1.4,
                lineCap: .round,
                dash: dash
            )
        )
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
}
