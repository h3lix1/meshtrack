// swift-tools-version: 6.2
import PackageDescription

/// Every first-party target is compiled with warnings-as-errors. The flag is
/// attached per-target (not via -Xswiftc) so it never poisons dependency builds.
let strict: [SwiftSetting] = [
    .unsafeFlags(["-warnings-as-errors"])
]

let package = Package(
    name: "Meshtrack",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "meshtrackd", targets: ["meshtrackd"]),
        .library(name: "Domain", targets: ["Domain"]),
        .library(name: "App", targets: ["App"])
    ],
    dependencies: [
        // Versions are floors; Package.resolved is the reproducible lock.
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf", from: "1.28.0"),
        .package(url: "https://github.com/jpsim/Yams", from: "5.1.0"),
        .package(url: "https://github.com/emqx/CocoaMQTT", from: "2.1.0")
    ],
    targets: [
        // ---- Domain: PURE. Imports nothing but the standard library. -----------
        .target(
            name: "Domain",
            swiftSettings: strict
        ),

        // ---- Generated protobufs (vendored meshtastic/protobufs) ---------------
        .target(
            name: "MeshProtos",
            dependencies: [.product(name: "SwiftProtobuf", package: "swift-protobuf")],
            swiftSettings: strict
        ),

        // ---- Adapters / outer ring ---------------------------------------------
        .target(
            name: "Persistence",
            dependencies: ["Domain", .product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: strict
        ),
        .target(
            name: "Transport",
            dependencies: ["Domain", "MeshProtos", .product(name: "CocoaMQTT", package: "CocoaMQTT")],
            swiftSettings: strict
        ),
        .target(
            name: "RuleEngine",
            dependencies: ["Domain"],
            swiftSettings: strict
        ),
        .target(
            name: "Provisioning",
            dependencies: ["Domain", "MeshProtos"],
            swiftSettings: strict
        ),
        .target(
            name: "Ingest",
            dependencies: ["Domain", "Transport", "Persistence", "MeshProtos"],
            swiftSettings: strict
        ),
        .target(
            name: "Crypto",
            dependencies: ["Domain"],
            swiftSettings: strict
        ),
        .target(
            name: "Logging",
            dependencies: ["Domain"],
            swiftSettings: strict
        ),
        .target(
            name: "Delivery",
            dependencies: ["RuleEngine"],
            swiftSettings: strict
        ),
        .target(
            name: "Firmware",
            swiftSettings: strict
        ),

        // ---- Test/acceptance harness -------------------------------------------
        .target(
            name: "Scenario",
            dependencies: [
                "Domain", "RuleEngine", "Persistence", "Transport",
                .product(name: "Yams", package: "Yams")
            ],
            exclude: ["SCHEMA.md"],
            swiftSettings: strict
        ),

        // ---- UI + composition roots --------------------------------------------
        .target(
            name: "App",
            dependencies: ["Domain", "Persistence", "RuleEngine"],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "meshtrackd",
            dependencies: [
                "Domain", "Persistence", "Transport", "RuleEngine",
                "Provisioning", "Ingest", "Crypto", "Logging", "Delivery", "Firmware", "MeshProtos"
            ],
            swiftSettings: strict
        ),
        .executableTarget(
            name: "MeshtrackSnapshot",
            dependencies: ["App", "Domain", "Persistence"],
            swiftSettings: strict
        ),

        // ---- Tests --------------------------------------------------------------
        .testTarget(name: "DomainTests", dependencies: ["Domain"], swiftSettings: strict),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "Domain"], swiftSettings: strict),
        .testTarget(name: "TransportTests", dependencies: ["Transport", "Domain"], swiftSettings: strict),
        .testTarget(name: "RuleEngineTests", dependencies: ["RuleEngine", "Domain"], swiftSettings: strict),
        .testTarget(
            name: "ProvisioningTests",
            dependencies: ["Provisioning", "Domain"],
            swiftSettings: strict
        ),
        .testTarget(name: "ScenarioTests", dependencies: ["Scenario"], swiftSettings: strict),
        .testTarget(
            name: "IngestTests",
            dependencies: ["Ingest", "Transport", "Persistence", "Domain", "MeshProtos"],
            swiftSettings: strict
        ),
        .testTarget(name: "CryptoTests", dependencies: ["Crypto", "Domain"], swiftSettings: strict),
        .testTarget(name: "LoggingTests", dependencies: ["Logging", "Domain"], swiftSettings: strict),
        .testTarget(name: "FirmwareTests", dependencies: ["Firmware"], swiftSettings: strict),
        .testTarget(name: "AppTests", dependencies: ["App", "Persistence", "Domain"], swiftSettings: strict)
    ],
    swiftLanguageModes: [.v6]
)
