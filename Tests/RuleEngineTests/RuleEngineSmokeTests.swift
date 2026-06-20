@testable import RuleEngine
import Testing

@Suite("RuleEngine (placeholder)")
struct RuleEngineSmokeTests {
    @Test
    func `module is linkable`() {
        #expect(RuleEngineModule.name == "RuleEngine")
    }
}
