@testable import App
import Foundation
import Testing

/// Env-gated live smoke: only runs when a broker is configured, so the normal
/// offline `make verify` skips it. Run against the live mesh with:
///   MESHTRACK_MQTT_HOST=mqtt.bayme.sh MESHTRACK_MQTT_USER=… MESHTRACK_MQTT_PASS=… \
///   MESHTRACK_MQTT_TOPIC=msh/US/bayarea/2/e/# swift test --filter LiveCoordinator
@Suite("LiveCoordinator (live broker smoke — env-gated)")
@MainActor
struct LiveCoordinatorSmokeTests {
    @Test(
        .enabled(if: ProcessInfo.processInfo.environment["MESHTRACK_MQTT_HOST"] != nil)
    )
    func `connects to the configured broker and decodes live packets`() async throws {
        let config = try #require(LiveCoordinator.environmentConfig())
        let coordinator = try LiveCoordinator(config: config)
        coordinator.start()
        try await Task.sleep(for: .seconds(12))
        let count = coordinator.viewModel.packetsObserved
        let nodes = coordinator.viewModel.nodes.count
        coordinator.stop()
        print("live smoke: \(count) packets decoded, \(nodes) positioned nodes from \(config.host)")
        #expect(count > 0)
    }
}
