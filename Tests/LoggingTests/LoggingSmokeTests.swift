@testable import Logging
import Testing

@Suite("Logging (placeholder)")
struct LoggingSmokeTests {
    @Test func `module links`() {
        #expect(LoggingModule.name == "Logging")
    }
}
