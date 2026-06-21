// WebhookNotifier — posts notifications to an ntfy / generic webhook URL
// (SPEC §2.6 pluggable delivery). ntfy uses the body as the message and a `Title`
// header. Network I/O; best-effort.

import Foundation
import RuleEngine

public struct WebhookNotifier: Notifier {
    private let url: URL
    private let session: URLSession

    public init(url: URL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    public func send(_ notification: AlertNotification) async {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(notification.title, forHTTPHeaderField: "Title")
        request.httpBody = Data(notification.body.utf8)
        _ = try? await session.data(for: request)
    }
}
