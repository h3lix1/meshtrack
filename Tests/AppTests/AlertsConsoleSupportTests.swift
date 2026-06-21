@testable import App
import Domain
import RuleEngine
import Testing

@Suite("Alerts console pure support (severity, formatting)")
struct AlertsConsoleSupportTests {
    @Test
    func `severity ranks ownership-critical types above informational ones`() {
        #expect(AlertSeverity.rank(.voltageBelow) > AlertSeverity.rank(.batteryBelow))
        #expect(AlertSeverity.rank(.batteryBelow) > AlertSeverity.rank(.stale))
        #expect(AlertSeverity.rank(.stale) > AlertSeverity.rank(.channelUtilHigh))
        #expect(AlertSeverity.rank(.newNodeSeen) == 0)
    }

    @Test
    func `duration formats seconds, minutes, and hours`() {
        #expect(Format.duration(45) == "45s")
        #expect(Format.duration(90) == "1m 30s")
        #expect(Format.duration(3661) == "1h 1m")
    }
}
