@testable import Provisioning
import Testing

@Suite("Provisioning (placeholder)")
struct ProvisioningSmokeTests {
    @Test
    func `module is linkable`() {
        #expect(ProvisioningModule.name == "Provisioning")
    }
}
