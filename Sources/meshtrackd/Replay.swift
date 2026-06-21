// Replay diagnostic: run a captured corpus through the REAL pipeline (decode +
// AES-CTR decrypt + dedup + persist) and print what came out. Validates the full
// ingestion stack against real traffic.
//
//   swift run meshtrackd replay <corpusDir>
//
// Uses the well-known Meshtastic default channel PSK, which the public
// MediumFast/LongFast channels use, applied to every channel hash.

import Crypto
import Domain
import Foundation
import Ingest
import Persistence
import Transport

enum Replay {
    /// The well-known Meshtastic default channel key (PSK index 1, "AQ==" expanded).
    static let defaultKey = ChannelKey(psk: [
        0xD4, 0xF1, 0xBB, 0x3A, 0x20, 0x29, 0x07, 0x59,
        0xF0, 0xBC, 0xFF, 0xAB, 0xCF, 0x4E, 0x69, 0x01
    ])

    static func run(corpusDir: String, clock _: any Domain.Clock) async {
        do {
            let store = try MeshStore(DatabaseConnection.inMemory())
            let decoder = PacketDecoder(
                keyStore: DefaultChannelKeyStore(key: defaultKey),
                decryptor: AESCTRPacketDecryptor()
            )
            let adapter = try ReplayAdapter(directory: URL(filePath: corpusDir))
            let summary = try await IngestPipeline(store: store, decoder: decoder).run(adapter)

            print("=== replay of \(corpusDir) ===")
            print("frames processed: \(summary.framesProcessed)")
            print("packets decoded: \(summary.packetsDecoded)")
            print("decode errors: \(summary.decodeErrors)")
            print("observations: \(summary.observationsRecorded)")
            print("duplicate deliveries: \(summary.duplicateDeliveriesSkipped)")
            print("telemetry points: \(summary.telemetryPointsRecorded)")
            print("position fixes: \(summary.positionFixesRecorded)")
            print("extractions deduped: \(summary.extractionsDeduped)")
        } catch {
            print("replay failed: \(error)")
        }
    }
}

/// Returns the default channel key for every channel hash (the public channels
/// all share the default PSK).
private struct DefaultChannelKeyStore: KeyStore {
    let key: ChannelKey
    func key(forChannelHash _: UInt32) -> ChannelKey? {
        key
    }
}
