@testable import App
import Domain
import Testing

@Suite("PortCatalog — descriptions + fallback")
struct PortCatalogTests {
    @Test
    func `the modelled MeshPorts map to their canonical names`() {
        #expect(PortCatalog.descriptor(for: .textMessage).name == "TEXT_MESSAGE_APP")
        #expect(PortCatalog.descriptor(for: .position).name == "POSITION_APP")
        #expect(PortCatalog.descriptor(for: .nodeInfo).name == "NODEINFO_APP")
        #expect(PortCatalog.descriptor(for: .routing).name == "ROUTING_APP")
        #expect(PortCatalog.descriptor(for: .admin).name == "ADMIN_APP")
        #expect(PortCatalog.descriptor(for: .telemetry).name == "TELEMETRY_APP")
        #expect(PortCatalog.descriptor(for: .mapReport).name == "MAP_REPORT_APP")
        #expect(PortCatalog.descriptor(for: .waypoint).name == "WAYPOINT_APP")
    }

    @Test
    func `every descriptor carries a non-empty summary`() {
        for port in MeshPort.allModelled {
            #expect(!PortCatalog.descriptor(for: port).summary.isEmpty)
        }
    }

    @Test
    func `a catalogued raw port resolves by number`() {
        let descriptor = PortCatalog.descriptor(for: .other(66))
        #expect(descriptor.name == "RANGE_TEST_APP")
        #expect(descriptor.rawValue == 66)
    }

    @Test
    func `an unknown raw port synthesises a stable descriptor`() {
        let descriptor = PortCatalog.descriptor(for: .other(199))
        #expect(descriptor.rawValue == 199)
        #expect(descriptor.name == "PORT_199")
        #expect(!descriptor.summary.isEmpty)
    }

    @Test
    func `port number round-trips through the descriptor`() {
        for port in MeshPort.allModelled {
            #expect(PortCatalog.descriptor(for: port).rawValue == port.portNumRawValue)
        }
    }
}

private extension MeshPort {
    /// The modelled (non-`.other`) ports, for catalogue-coverage tests.
    static let allModelled: [MeshPort] = [
        .textMessage, .position, .nodeInfo, .routing, .admin, .waypoint, .telemetry, .mapReport
    ]
}
