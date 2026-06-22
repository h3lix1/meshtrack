@testable import App
import Domain
import Testing

@Suite("LiveStartupPolicy (launch-time auto-connect decision, Finding 2)")
struct LiveStartupPolicyTests {
    @Test
    func `auto-connect ON + a connectable source ⇒ connect on launch`() {
        let settings = AppSettings(autoConnect: true)
        #expect(LiveStartupPolicy.shouldConnectOnLaunch(settings: settings, hasConnectableSource: true))
    }

    @Test
    func `auto-connect ON but nothing connectable ⇒ stay offline`() {
        let settings = AppSettings(autoConnect: true)
        #expect(!LiveStartupPolicy.shouldConnectOnLaunch(settings: settings, hasConnectableSource: false))
    }

    @Test
    func `auto-connect OFF never connects on launch, even with a connectable source`() {
        let settings = AppSettings(autoConnect: false)
        #expect(!LiveStartupPolicy.shouldConnectOnLaunch(settings: settings, hasConnectableSource: true))
        #expect(!LiveStartupPolicy.shouldConnectOnLaunch(settings: settings, hasConnectableSource: false))
    }
}
