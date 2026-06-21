// MQTTAdapter — MeshTransport over an MQTT broker (SPEC §2.4/§2.5).
//
// Subscribes to Meshtastic topics and emits each ServiceEnvelope as an
// InboundFrame (raw payload bytes; decode/decrypt is the pipeline's job). The
// CocoaMQTT client + delegate are non-Sendable, so they're confined to a
// queue-backed MQTTSession (@unchecked Sendable). Network I/O is best-effort and
// not unit-tested (excluded from the coverage metric); the tested logic is
// MeshtasticTopic. Credentials come from the caller (Keychain), never the repo.

import CocoaMQTT
import Domain
import Foundation

/// Connection settings for `MQTTAdapter`. `username`/`password` are supplied by
/// the caller from Keychain and never persisted to the repo or DB.
public struct MQTTConfig: Sendable {
    public var host: String
    public var port: UInt16
    public var username: String?
    public var password: String?
    public var useTLS: Bool
    public var allowUntrustedCert: Bool
    public var topics: [String]
    public var clientID: String

    public init(
        host: String,
        port: UInt16 = 1883,
        username: String? = nil,
        password: String? = nil,
        useTLS: Bool = false,
        allowUntrustedCert: Bool = false,
        topics: [String] = ["msh/+/2/e/#"],
        clientID: String = "meshtrack-\(UInt32.random(in: 0 ... .max))"
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.useTLS = useTLS
        self.allowUntrustedCert = allowUntrustedCert
        self.topics = topics
        self.clientID = clientID
    }
}

public struct MQTTAdapter: MeshTransport {
    private let config: MQTTConfig
    private let clock: any Clock

    public init(config: MQTTConfig, clock: any Clock) {
        self.config = config
        self.clock = clock
    }

    public func frames() -> AsyncStream<InboundFrame> {
        let config = config
        let clock = clock
        return AsyncStream { continuation in
            let session = MQTTSession(config: config, clock: clock, continuation: continuation)
            continuation.onTermination = { _ in session.stop() }
            session.start()
        }
    }
}

private final class MQTTSession: NSObject, CocoaMQTTDelegate, @unchecked Sendable {
    private let mqtt: CocoaMQTT
    private let continuation: AsyncStream<InboundFrame>.Continuation
    private let clock: any Clock
    private let topics: [String]

    init(config: MQTTConfig, clock: any Clock, continuation: AsyncStream<InboundFrame>.Continuation) {
        self.continuation = continuation
        self.clock = clock
        topics = config.topics
        mqtt = CocoaMQTT(clientID: config.clientID, host: config.host, port: config.port)
        super.init()
        mqtt.username = config.username
        mqtt.password = config.password
        mqtt.enableSSL = config.useTLS
        mqtt.allowUntrustCACertificate = config.allowUntrustedCert
        mqtt.autoReconnect = true
        mqtt.delegate = self
    }

    func start() {
        _ = mqtt.connect()
    }

    func stop() {
        mqtt.disconnect()
    }

    func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        guard ack == .accept else { return }
        for topic in topics {
            mqtt.subscribe(topic, qos: .qos0)
        }
    }

    func mqtt(_: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id _: UInt16) {
        let topic = message.topic
        continuation.yield(InboundFrame(
            transport: .mqtt,
            topic: topic,
            payload: message.payload,
            receivedAt: clock.now(),
            gatewayID: MeshtasticTopic.parse(topic)?.gatewayID
        ))
    }

    func mqttDidDisconnect(_: CocoaMQTT, withError _: Error?) {
        continuation.finish()
    }

    // Required CocoaMQTTDelegate conformance — no-ops for a read-only subscriber.
    func mqtt(_: CocoaMQTT, didPublishMessage _: CocoaMQTTMessage, id _: UInt16) {}
    func mqtt(_: CocoaMQTT, didPublishAck _: UInt16) {}
    func mqtt(_: CocoaMQTT, didSubscribeTopics _: NSDictionary, failed _: [String]) {}
    func mqtt(_: CocoaMQTT, didUnsubscribeTopics _: [String]) {}
    func mqttDidPing(_: CocoaMQTT) {}
    func mqttDidReceivePong(_: CocoaMQTT) {}
}
