// MapPerfSignpost — lightweight Instruments hooks for the live Network map.
//
// These signposts make xctrace runs actionable: annotation sync, projection
// publication, spiderfy and overlay drawing show up as named intervals instead of
// anonymous SwiftUI/AppKit work.

import Foundation
import OSLog

enum MapPerfSignpost {
    private static let signposter = OSSignposter(
        subsystem: "com.meshtrack.app",
        category: "network-map"
    )

    static func interval<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: id)
        defer { signposter.endInterval(name, state) }
        return try work()
    }
}
