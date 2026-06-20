@testable import Scenario
import Testing

@Suite("Scenario (placeholder)")
struct ScenarioSmokeTests {
    @Test
    func `module is linkable`() {
        #expect(ScenarioModule.name == "Scenario")
    }
}
