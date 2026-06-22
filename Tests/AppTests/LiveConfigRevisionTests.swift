@testable import App
import Testing

@MainActor
@Suite("LiveConfigRevision (reconnect-on-save signal, Finding 1)")
struct LiveConfigRevisionTests {
    @Test
    func `starts at zero`() {
        #expect(LiveConfigRevision().token == 0)
    }

    @Test
    func `bump increments the token by one each call`() {
        let revision = LiveConfigRevision()
        revision.bump()
        #expect(revision.token == 1)
        revision.bump()
        revision.bump()
        #expect(revision.token == 3)
    }
}
