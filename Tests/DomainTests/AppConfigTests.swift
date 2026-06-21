import Domain
import Foundation
import Testing

@Suite("App configuration value types (Phase 8)")
struct AppConfigTests {
    @Test
    func `BrokerConfig defaults are TLS on, port 8883, the default topic`() {
        let config = BrokerConfig()
        #expect(config.port == 8883)
        #expect(config.useTLS)
        #expect(config.allowUntrustedCert == false)
        #expect(config.topics == [BrokerConfig.defaultTopic])
        #expect(config.username == nil)
    }

    @Test
    func `isConnectable requires a host and at least one non-empty topic`() {
        #expect(!BrokerConfig(host: "", topics: ["t"]).isConnectable) // no host
        #expect(!BrokerConfig(host: "h", topics: []).isConnectable) // no topic
        #expect(!BrokerConfig(host: "h", topics: [""]).isConnectable) // blank topic only
        #expect(BrokerConfig(host: "h", topics: ["msh/US/2/e/#"]).isConnectable)
    }

    @Test
    func `BrokerConfig round-trips through Codable without a password field`() throws {
        let config = BrokerConfig(
            host: "mqtt.bayme.sh", port: 8883, username: "clive",
            useTLS: true, allowUntrustedCert: false, topics: ["a", "b"], clientID: "mac"
        )
        let data = try JSONEncoder().encode(config)
        #expect(try JSONDecoder().decode(BrokerConfig.self, from: data) == config)
        // The non-secret contract: there is no password key to leak.
        let json = try #require(String(bytes: data, encoding: .utf8))
        #expect(!json.contains("password"))
    }

    @Test
    func `AppSettings defaults are sensible and round-trip`() throws {
        let settings = AppSettings.default
        #expect(settings.refreshIntervalSeconds == 3)
        #expect(settings.useMetricUnits)
        #expect(settings.telemetryRetentionDays == 30)
        #expect(settings.autoConnect)
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data) == settings)
    }

    @Test
    func `NodeManagement gates ownership rules only when managed`() {
        #expect(NodeManagement(isManaged: true).evaluatesOwnershipRules)
        #expect(!NodeManagement(isManaged: false).evaluatesOwnershipRules)
        #expect(!NodeManagement.unowned.evaluatesOwnershipRules)
    }
}
