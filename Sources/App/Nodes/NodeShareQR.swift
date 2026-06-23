// NodeShareQR — a QR code for a node's share URL (Phase 7 G3).
//
// Encodes a node's identity into a scannable QR via CoreImage's
// `CIQRCodeGenerator`, rendered to a SwiftUI `Image`. The share payload is a
// stable `meshtrack://` URL carrying the node's hex id so another operator (or a
// phone) can resolve the same node. The generation is total — every failure path
// returns `nil` rather than force-unwrapping — so it is safe under
// warnings-as-errors and the no-force-unwrap rule.

import CoreImage
import CoreImage.CIFilterBuiltins
import Domain
import SwiftUI

/// Builds the share URL + QR image for a node.
public enum NodeShareQR {
    /// The canonical share URL for a node number, e.g.
    /// `meshtrack://node/!a1b2c3d4`. Stable and round-trippable.
    public static func shareURL(forNodeNum nodeNum: Int64) -> String {
        "meshtrack://node/" + hexID(nodeNum)
    }

    /// A QR `Image` encoding `string`, scaled up to roughly `size` points with
    /// nearest-neighbour interpolation (crisp squares). Returns `nil` if the
    /// string can't be encoded or rasterised.
    public static func image(for string: String, size: CGFloat = 200) -> Image? {
        guard let cgImage = cgImage(for: string, size: size) else {
            return nil
        }
        return Image(decorative: cgImage, scale: 1, orientation: .up)
    }

    /// The QR for a node number's share URL.
    public static func nodeImage(nodeNum: Int64, size: CGFloat = 200) -> Image? {
        image(for: shareURL(forNodeNum: nodeNum), size: size)
    }

    /// Rasterise `string` into a `CGImage` QR of approximately `size` points.
    /// Separated out so it is testable without SwiftUI.
    static func cgImage(for string: String, size: CGFloat) -> CGImage? {
        guard let data = string.data(using: .utf8), !data.isEmpty, size > 0 else {
            return nil
        }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else {
            return nil
        }
        // Scale the 1px-per-module output up to the requested point size.
        let extent = output.extent
        guard extent.width > 0, extent.height > 0 else {
            return nil
        }
        let scale = max(1, size / extent.width)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: nil)
        return context.createCGImage(scaled, from: scaled.extent)
    }

    /// The `!aabbccdd` hex id for a node number.
    static func hexID(_ nodeNum: Int64) -> String {
        NodeID.hex(UInt32(truncatingIfNeeded: nodeNum))
    }
}
