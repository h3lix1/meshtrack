@testable import Crypto
import Testing

@Suite("Crypto (placeholder)")
struct CryptoSmokeTests {
    @Test func `module links`() {
        #expect(CryptoModule.name == "Crypto")
    }
}
