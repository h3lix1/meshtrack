@testable import App
import CoreGraphics
import Testing

/// Unit tests for the PURE viewport-culling helpers on `TraceRenderer`. The drawing
/// paths route through these, but GraphicsContext output is not headless-assertable, so
/// we exercise the geometry directly. The helpers use a generous margin (80pt) so
/// blurred glows / labels / comet trails bleeding in from just off-screen survive.
@Suite("Trace viewport culling")
@MainActor
struct TraceCullingTests {
    private let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
    private let margin: CGFloat = 80

    // MARK: isPointVisible

    @Test
    func `point inside bounds is visible`() {
        #expect(
            TraceRenderer.isPointVisible(CGPoint(x: 100, y: 50), in: bounds, margin: margin)
        )
    }

    @Test
    func `point far outside beyond the margin is not visible`() {
        // 1000pt to the right is well past the 80pt margin.
        #expect(
            !TraceRenderer.isPointVisible(CGPoint(x: 1000, y: 50), in: bounds, margin: margin)
        )
        // Far above, too.
        #expect(
            !TraceRenderer.isPointVisible(CGPoint(x: 100, y: -500), in: bounds, margin: margin)
        )
    }

    @Test
    func `point just outside but within the margin is visible`() {
        // 40pt left of the edge (x = -40) is within the 80pt margin.
        #expect(
            TraceRenderer.isPointVisible(CGPoint(x: -40, y: 50), in: bounds, margin: margin)
        )
        // 40pt below the bottom edge (y = 140) is within the margin.
        #expect(
            TraceRenderer.isPointVisible(CGPoint(x: 100, y: 140), in: bounds, margin: margin)
        )
    }

    // MARK: isSegmentVisible

    @Test
    func `segment fully outside on one side is not visible`() {
        // Both endpoints far to the right, well past the margin.
        #expect(
            !TraceRenderer.isSegmentVisible(
                from: CGPoint(x: 500, y: 20),
                to: CGPoint(x: 700, y: 80),
                in: bounds,
                margin: margin
            )
        )
    }

    @Test
    func `segment crossing the viewport is visible`() {
        // One endpoint inside the bounds, the other far off to the left.
        #expect(
            TraceRenderer.isSegmentVisible(
                from: CGPoint(x: 100, y: 50),
                to: CGPoint(x: -1000, y: 50),
                in: bounds,
                margin: margin
            )
        )
    }

    @Test
    func `diagonal segment whose bbox touches the margin is visible`() {
        // Both endpoints lie outside the raw bounds, but the segment's bounding box
        // overlaps the margin-expanded viewport: it spans from above-left to inside the
        // top-left margin band, so the conservative bbox test keeps it.
        #expect(
            TraceRenderer.isSegmentVisible(
                from: CGPoint(x: -60, y: -60),
                to: CGPoint(x: -10, y: -10),
                in: bounds,
                margin: margin
            )
        )
    }
}
