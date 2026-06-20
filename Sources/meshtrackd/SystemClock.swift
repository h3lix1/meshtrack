// SystemClock — the real wall-clock adapter for the `Clock` port.
//
// Lives in the composition root, NEVER in Domain. This is the only place a
// `Date()` call backs the clock; Domain reads time exclusively through the port.

import Domain
import Foundation

public struct SystemClock: Domain.Clock {
    public init() {}

    public func now() -> Instant {
        let secondsSinceEpoch = Date().timeIntervalSince1970
        return Instant(nanosecondsSinceEpoch: Int64((secondsSinceEpoch * 1_000_000_000).rounded()))
    }
}
