// ConsoleNotifier — logs notifications via an injectable sink (default: stdout).
// Useful for dev/CLI and as the simplest Notifier adapter.

import Foundation
import RuleEngine

public struct ConsoleNotifier: Notifier {
    private let sink: @Sendable (String) -> Void

    public init(sink: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.sink = sink
    }

    public func send(_ notification: AlertNotification) async {
        let mark = notification.isResolution ? "✓" : "🔔"
        sink("\(mark) \(notification.title) — \(notification.body)")
    }
}
