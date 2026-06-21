@testable import App
import SwiftUI
import Testing

@Suite("AppModel section registry")
@MainActor
struct AppModelTests {
    @Test
    func `the default registry provides a view for every section`() {
        let model = AppModel(nodes: SampleNetwork.nodes, traces: SampleNetwork.traces, live: false)
        for section in AppSection.allCases {
            #expect(model.isRegistered(section), "no provider for \(section.rawValue)")
        }
    }

    @Test
    func `register replaces a section's provider (feature streams add without editing the shell)`() {
        let model = AppModel()
        // A feature stream registers its own section view from its own file.
        model.register(.alerts) { AnyView(Text("custom alerts")) }
        #expect(model.isRegistered(.alerts))
        // Other sections are untouched.
        #expect(model.isRegistered(.network))
    }

    @Test
    func `the model carries the sample data and live flag it was built with`() {
        let model = AppModel(nodes: SampleNetwork.nodes, traces: SampleNetwork.traces, live: false)
        #expect(model.live == false)
        #expect(model.nodes.count == SampleNetwork.nodes.count)
        #expect(model.traces.count == SampleNetwork.traces.count)
    }
}
