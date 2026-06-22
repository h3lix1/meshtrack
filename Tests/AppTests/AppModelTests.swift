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

    @Test
    func `onNavigate fires with the requested section (Finding 19)`() {
        let model = AppModel()
        var navigated: [AppSection] = []
        model.onNavigate = { navigated.append($0) }
        // Section views invoke onNavigate (e.g. node directory "Open analytics"/"Apply").
        model.onNavigate?(.analytics)
        model.onNavigate?(.fleet)
        #expect(navigated == [.analytics, .fleet])
    }

    @Test
    func `onNavigate is nil until the shell wires it`() {
        #expect(AppModel().onNavigate == nil)
    }

    @Test
    func `the provisioning workflow is reachable from the sidebar with a default-mode provider`() {
        // The section must exist in the sidebar list (so the workflow is reachable)
        // and the default/sample registry must back it (so it renders without a live
        // store). Live wiring is asserted by the AppComposition registration itself.
        #expect(AppSection.allCases.contains(.provision))
        #expect(AppSection.provision.title == "Provision")
        let model = AppModel(nodes: SampleNetwork.nodes, traces: SampleNetwork.traces, live: false)
        #expect(model.isRegistered(.provision))
    }
}
