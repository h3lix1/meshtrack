// LiveBrokerSettings — the broker configuration read from the process
// environment (never the repo, never the DB). Pure value type: it decodes the
// `MESHTRACK_MQTT_*` variables and builds the Transport `MQTTConfig` the
// `LiveCoordinator` connects with. Credentials are held only in memory and are
// never logged (only `host`/`topic` are surfaced to the UI).
//
//   MESHTRACK_MQTT_HOST   broker host (required to go live)
//   MESHTRACK_MQTT_PORT   broker port (default 8883 with TLS, else 1883)
//   MESHTRACK_MQTT_USER   username (optional)
//   MESHTRACK_MQTT_PASS   password (optional)
//   MESHTRACK_MQTT_TLS    "1" to enable TLS
//   MESHTRACK_MQTT_TOPIC  subscribe topic (default the Bay Area encrypted feed)

import Foundation
import Transport

/// Broker connection settings decoded from the environment.
struct LiveBrokerSettings: Equatable {
    var host: String
    var port: UInt16
    var username: String?
    var password: String?
    var useTLS: Bool
    var topic: String

    static let defaultTopic = "msh/US/bayarea/2/e/#"

    /// Decode settings from the given environment, or `nil` when no broker host is
    /// configured (the signal to fall back to sample data). The port defaults to
    /// the standard MQTT-over-TLS port (8883) when TLS is on, else 1883.
    static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> LiveBrokerSettings? {
        guard let host = env["MESHTRACK_MQTT_HOST"], !host.isEmpty else { return nil }
        let useTLS = env["MESHTRACK_MQTT_TLS"] == "1"
        let port = env["MESHTRACK_MQTT_PORT"].flatMap(UInt16.init) ?? (useTLS ? 8883 : 1883)
        let topic = env["MESHTRACK_MQTT_TOPIC"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultTopic
        return LiveBrokerSettings(
            host: host,
            port: port,
            username: env["MESHTRACK_MQTT_USER"],
            password: env["MESHTRACK_MQTT_PASS"],
            useTLS: useTLS,
            topic: topic
        )
    }

    /// The Transport config the `MQTTAdapter` connects with.
    func makeMQTTConfig() -> MQTTConfig {
        MQTTConfig(
            host: host,
            port: port,
            username: username,
            password: password,
            useTLS: useTLS,
            topics: [topic]
        )
    }
}
