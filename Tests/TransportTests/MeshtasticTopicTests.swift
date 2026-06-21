import Testing
@testable import Transport

@Suite("MeshtasticTopic parsing")
struct MeshtasticTopicTests {
    @Test
    func `parses a standard encrypted topic`() throws {
        let topic = try #require(MeshtasticTopic.parse("msh/US/2/e/MediumFast/!a1b2c3d4"))
        #expect(topic.region == "US")
        #expect(topic.kind == .encrypted)
        #expect(topic.channel == "MediumFast")
        #expect(topic.gatewayID == "!a1b2c3d4")
    }

    @Test
    func `handles a multi-segment region`() throws {
        let topic = try #require(MeshtasticTopic.parse("msh/US/bayarea/2/e/MediumFast/!c0ffee00"))
        #expect(topic.region == "US/bayarea")
        #expect(topic.channel == "MediumFast")
        #expect(topic.gatewayID == "!c0ffee00")
    }

    @Test
    func `recognises the json kind`() throws {
        let topic = try #require(MeshtasticTopic.parse("msh/EU_868/2/json/LongFast/!deadbeef"))
        #expect(topic.kind == .json)
    }

    @Test
    func `an unknown kind falls back to .other`() throws {
        let topic = try #require(MeshtasticTopic.parse("msh/US/2/stat/!a1b2c3d4"))
        #expect(topic.kind == .other)
    }

    @Test
    func `a topic without channel/gateway still parses`() throws {
        let topic = try #require(MeshtasticTopic.parse("msh/US/2/e"))
        #expect(topic.channel == nil)
        #expect(topic.gatewayID == nil)
    }

    @Test
    func `non-Meshtastic topics return nil`() {
        #expect(MeshtasticTopic.parse("home/sensor/temp") == nil)
        #expect(MeshtasticTopic.parse("msh/US/onlyregion") == nil) // no version segment
        #expect(MeshtasticTopic.parse("") == nil)
    }
}
