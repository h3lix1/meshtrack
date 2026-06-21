// MeshtrackSnapshot — renders SwiftUI views to PNGs via ImageRenderer (headless,
// no running app). Used to self-validate the GUI's appearance during development.
//
//   swift run MeshtrackSnapshot [outputDir]

import App
import AppKit
import Foundation
import SwiftUI

@main
enum Snapshot {
    @MainActor
    static func main() {
        let outputDir = CommandLine.arguments.dropFirst().first ?? "Snapshots"
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        let nodes = SampleNetwork.nodes
        let traces = SampleNetwork.traces
        for section in AppSection.allCases {
            write(
                RootView(section: section, nodes: nodes, traces: traces).frame(width: 1400, height: 880),
                to: "\(outputDir)/\(section.rawValue).png"
            )
        }
        write(
            NodeDetailView(node: nodes[1], region: "US", role: "ROUTER", armedForPreview: true),
            to: "\(outputDir)/node-detail.png"
        )
        print("snapshots written to \(outputDir)/")
    }

    @MainActor
    static func write(_ view: some View, to path: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            print("render failed for \(path)")
            return
        }
        try? png.write(to: URL(fileURLWithPath: path))
    }
}
