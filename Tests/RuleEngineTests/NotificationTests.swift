import Domain
@testable import RuleEngine
import Testing

@Suite("Notification formatting + dispatch")
struct NotificationTests {
    private actor RecordingNotifier: Notifier {
        private(set) var sent: [AlertNotification] = []
        func send(_ notification: AlertNotification) async {
            sent.append(notification)
        }
    }

    private func alert(_ type: AlertType, node: UInt32, detail: String) -> Alert {
        Alert(
            type: type, nodeNum: node, detail: detail, state: .firing, firedAt: .epoch,
            resolvedAt: nil, ackedAt: nil, snoozedUntil: nil, cooldownSeconds: 0, wasAnnounced: true
        )
    }

    @Test
    func `a fired event formats title + body with the node hex id and detail`() {
        let note = NotificationFormatter.notification(
            for: .fired(alert(.batteryBelow, node: 0xA1B2_C3D4, detail: "battery 15% < 20%"))
        )
        #expect(note.title == "Battery low")
        #expect(note.body == "!a1b2c3d4: battery 15% < 20%")
        #expect(note.isResolution == false)
    }

    @Test
    func `a resolved event is marked as a resolution`() {
        let note = NotificationFormatter.notification(
            for: .resolved(alert(.stale, node: 7, detail: "silent"))
        )
        #expect(note.title == "Resolved — Node went silent")
        #expect(note.isResolution)
    }

    @Test
    func `the dispatcher delivers every event through the notifier`() async {
        let recorder = RecordingNotifier()
        let events: [AlertEvent] = [
            .fired(alert(.stale, node: 7, detail: "silent")),
            .resolved(alert(.stale, node: 8, detail: "silent"))
        ]
        await NotificationDispatcher(notifier: recorder).dispatch(events)
        let sent = await recorder.sent
        #expect(sent.count == 2)
        #expect(sent.map(\.isResolution) == [false, true])
    }
}
