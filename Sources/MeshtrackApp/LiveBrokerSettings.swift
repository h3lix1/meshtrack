// LiveBrokerSettings — the in-memory broker connection the `LiveCoordinator`
// connects with. Pure value type: it carries the non-secret `BrokerConfig` fields
// plus the password (held only in memory, never logged — only `host`/`topic` are
// surfaced to the UI) and builds the Transport `MQTTConfig`.
//
// PRIMARY path (Phase 8): built from a saved `BrokerConfig` (`ConfigGateway`) +
// the broker password (`CredentialStore`) via `from(config:password:)`.
//
// FALLBACK path: `fromEnvironment()` decodes the legacy `MESHTRACK_MQTT_*`
// variables, used only when no `BrokerConfig` has been saved yet — handy for
// `meshtrackd`/CI and for one-shot `swift run MeshtrackApp` smokes:
//
//   MESHTRACK_MQTT_HOST   broker host (required to use the fallback)
//   MESHTRACK_MQTT_PORT   broker port (default 8883 with TLS, else 1883)
//   MESHTRACK_MQTT_USER   username (optional)
//   MESHTRACK_MQTT_PASS   password (optional)
//   MESHTRACK_MQTT_TLS    "1" to enable TLS
//   MESHTRACK_MQTT_TOPIC  subscribe topic (default the Bay Area encrypted feed)

import Domain
import Foundation
import Transport

/// Broker connection settings, with the secret password resolved into memory.
struct LiveBrokerSettings: Equatable, Sendable {
    var host: String
    var port: UInt16
    var username: String?
    var password: String?
    var useTLS: Bool
    var allowUntrustedCert: Bool
    var topics: [String]
    var clientID: String

    static let defaultTopic = BrokerConfig.defaultTopic

    /// The broker host surfaced to the UI (status indicator, onboarding). Never the
    /// credentials.
    var displayHost: String { host }

    /// Build from a saved, non-secret `BrokerConfig` plus the resolved password from
    /// the `CredentialStore`. This is the PRIMARY Phase 8 path. Empty/blank topics
    /// are dropped, and an empty topic list falls back to the default feed so the
    /// adapter always has something to subscribe to.
    static func from(config: BrokerConfig, password: String?) -> LiveBrokerSettings {
        let topics = config.topics.filter { !$0.isEmpty }
        return LiveBrokerSettings(
            host: config.host,
            port: config.port,
            username: config.username,
            password: password,
            useTLS: config.useTLS,
            allowUntrustedCert: config.allowUntrustedCert,
            topics: topics.isEmpty ? [defaultTopic] : topics,
            clientID: config.clientID
        )
    }

    /// Decode settings from the given environment, or `nil` when no broker host is
    /// configured. FALLBACK only — used when no `BrokerConfig` has been saved. The
    /// port defaults to the standard MQTT-over-TLS port (8883) when TLS is on, else
    /// 1883.
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
            allowUntrustedCert: false,
            topics: [topic],
            clientID: ""
        )
    }

    /// The non-secret `BrokerConfig` equivalent of these settings — used to seed the
    /// config store from the env fallback so the saved-config path can take over.
    func makeBrokerConfig() -> BrokerConfig {
        BrokerConfig(
            host: host,
            port: port,
            username: username,
            useTLS: useTLS,
            allowUntrustedCert: allowUntrustedCert,
            topics: topics,
            clientID: clientID
        )
    }

    /// The Transport config the `MQTTAdapter` connects with. A blank `clientID`
    /// lets the adapter generate a stable random one (per `MQTTConfig`'s default).
    func makeMQTTConfig() -> MQTTConfig {
        if clientID.isEmpty {
            return MQTTConfig(
                host: host,
                port: port,
                username: username,
                password: password,
                useTLS: useTLS,
                allowUntrustedCert: allowUntrustedCert,
                topics: topics
            )
        }
        return MQTTConfig(
            host: host,
            port: port,
            username: username,
            password: password,
            useTLS: useTLS,
            allowUntrustedCert: allowUntrustedCert,
            topics: topics,
            clientID: clientID
        )
    }
}
