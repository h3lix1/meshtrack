@testable import Persistence
import Testing

@Suite("Persistence (placeholder)")
struct PersistenceSmokeTests {
    @Test
    func `module is linkable`() {
        #expect(PersistenceModule.name == "Persistence")
    }
}
