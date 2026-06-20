// Golden-corpus format + loader (SPEC §6, tier 4 = Replay).
//
// A corpus is a directory of two files (see Corpus/README.md):
//
//   <name>/
//     meta.json        — capture metadata (CorpusMeta)
//     frames.ndjson    — one CorpusFrame JSON object per line, in capture order
//
// The loader parses both with Foundation `JSONDecoder` (Transport MAY import
// Foundation; Domain may not) and surfaces every failure as a typed
// `ReplayError`. Parsing is total: malformed input never crashes, it throws.
//
// Field names on the wire are snake_case and map 1:1 to `InboundFrame`
// provenance via explicit CodingKeys (the port's `Transport` enum isn't Codable,
// so it is bridged through its string raw value).

import Domain
import Foundation

/// Capture metadata for a corpus (`meta.json`).
///
/// `synthetic` marks hand-constructed corpora whose payloads are opaque/raw
/// rather than real broker captures (Corpus/README.md). It defaults to `false`
/// so real captures need not set it.
public struct CorpusMeta: Sendable, Equatable, Codable {
    public let name: String
    public let source: String
    public let capturedAt: String
    public let topicFilter: String?
    public let frameCount: Int?
    public let synthetic: Bool
    public let notes: String?

    public init(
        name: String,
        source: String,
        capturedAt: String,
        topicFilter: String? = nil,
        frameCount: Int? = nil,
        synthetic: Bool = false,
        notes: String? = nil
    ) {
        self.name = name
        self.source = source
        self.capturedAt = capturedAt
        self.topicFilter = topicFilter
        self.frameCount = frameCount
        self.synthetic = synthetic
        self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case source
        case capturedAt = "captured_at"
        case topicFilter = "topic_filter"
        case frameCount = "frame_count"
        case synthetic
        case notes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        source = try container.decode(String.self, forKey: .source)
        capturedAt = try container.decode(String.self, forKey: .capturedAt)
        topicFilter = try container.decodeIfPresent(String.self, forKey: .topicFilter)
        frameCount = try container.decodeIfPresent(Int.self, forKey: .frameCount)
        synthetic = try container.decodeIfPresent(Bool.self, forKey: .synthetic) ?? false
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
    }
}

/// One on-disk frame record (`frames.ndjson`, one per line).
///
/// `payloadB64` is base64 of the raw on-the-wire bytes; `rxTimeNs` drives the
/// replay clock. Fields map 1:1 to `InboundFrame`.
public struct CorpusFrame: Sendable, Equatable, Codable {
    public let seq: Int
    public let rxTimeNs: Int64
    public let transport: InboundFrame.Transport
    public let topic: String?
    public let gatewayID: String?
    public let payloadB64: String

    public init(
        seq: Int,
        rxTimeNs: Int64,
        transport: InboundFrame.Transport,
        topic: String? = nil,
        gatewayID: String? = nil,
        payloadB64: String
    ) {
        self.seq = seq
        self.rxTimeNs = rxTimeNs
        self.transport = transport
        self.topic = topic
        self.gatewayID = gatewayID
        self.payloadB64 = payloadB64
    }

    private enum CodingKeys: String, CodingKey {
        case seq
        case rxTimeNs = "rx_time_ns"
        case transport
        case topic
        case gatewayID = "gateway_id"
        case payloadB64 = "payload_b64"
    }

    /// `InboundFrame.Transport` is defined by the frozen port and isn't `Codable`,
    /// so we bridge it through its string raw value here.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        seq = try container.decode(Int.self, forKey: .seq)
        rxTimeNs = try container.decode(Int64.self, forKey: .rxTimeNs)
        let transportRaw = try container.decode(String.self, forKey: .transport)
        guard let transport = InboundFrame.Transport(rawValue: transportRaw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .transport,
                in: container,
                debugDescription: "unknown transport '\(transportRaw)'"
            )
        }
        self.transport = transport
        topic = try container.decodeIfPresent(String.self, forKey: .topic)
        gatewayID = try container.decodeIfPresent(String.self, forKey: .gatewayID)
        payloadB64 = try container.decode(String.self, forKey: .payloadB64)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(seq, forKey: .seq)
        try container.encode(rxTimeNs, forKey: .rxTimeNs)
        try container.encode(transport.rawValue, forKey: .transport)
        try container.encodeIfPresent(topic, forKey: .topic)
        try container.encodeIfPresent(gatewayID, forKey: .gatewayID)
        try container.encode(payloadB64, forKey: .payloadB64)
    }
}

/// Errors raised while loading or decoding a corpus. Typed so callers can react
/// precisely and so failures are never silent.
public enum ReplayError: Error, Equatable, Sendable {
    /// The corpus directory does not exist or is not a directory.
    case corpusNotFound(path: String)
    /// A required file (`meta.json` / `frames.ndjson`) is missing.
    case missingFile(name: String, path: String)
    /// `meta.json` could not be decoded.
    case malformedMeta(reason: String)
    /// A line of `frames.ndjson` could not be decoded. `line` is 1-based.
    case malformedFrame(line: Int, reason: String)
    /// A frame's `payload_b64` was not valid base64.
    case invalidBase64(seq: Int, value: String)
}

/// A fully-loaded corpus: validated metadata plus frames sorted by `seq`.
///
/// Loading is eager and throwing, so a malformed corpus fails fast at the call
/// site rather than mid-stream. `frames()` on `ReplayAdapter` then just replays
/// what was loaded here.
public struct Corpus: Sendable, Equatable {
    public let meta: CorpusMeta
    /// Frames in ascending `seq` order, ready to emit.
    public let frames: [CorpusFrame]

    /// Decode the raw payload bytes for a frame, validating base64.
    public static func payloadBytes(of frame: CorpusFrame) throws -> [UInt8] {
        guard let data = Data(base64Encoded: frame.payloadB64) else {
            throw ReplayError.invalidBase64(seq: frame.seq, value: frame.payloadB64)
        }
        return [UInt8](data)
    }

    /// Load and validate a corpus directory.
    ///
    /// - Throws: `ReplayError` for a missing directory/file, undecodable
    ///   `meta.json`, or any undecodable / non-base64 `frames.ndjson` line.
    public static func load(directory url: URL) throws -> Corpus {
        let fileManager = FileManager.default
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw ReplayError.corpusNotFound(path: url.path)
        }

        let metaURL = url.appendingPathComponent("meta.json")
        let framesURL = url.appendingPathComponent("frames.ndjson")

        let meta = try loadMeta(at: metaURL)
        let frames = try loadFrames(at: framesURL)
        return Corpus(meta: meta, frames: frames.sorted { $0.seq < $1.seq })
    }

    private static func loadMeta(at url: URL) throws -> CorpusMeta {
        guard let data = try? Data(contentsOf: url) else {
            throw ReplayError.missingFile(name: "meta.json", path: url.path)
        }
        do {
            return try JSONDecoder().decode(CorpusMeta.self, from: data)
        } catch {
            throw ReplayError.malformedMeta(reason: String(describing: error))
        }
    }

    private static func loadFrames(at url: URL) throws -> [CorpusFrame] {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            throw ReplayError.missingFile(name: "frames.ndjson", path: url.path)
        }
        let decoder = JSONDecoder()
        var frames: [CorpusFrame] = []
        // 1-based line numbers including blanks, so error messages point at the
        // exact source line; blank/whitespace-only lines are skipped.
        for (index, line) in raw.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let lineData = trimmed.data(using: .utf8) else {
                throw ReplayError.malformedFrame(line: index + 1, reason: "line is not valid UTF-8")
            }
            do {
                let frame = try decoder.decode(CorpusFrame.self, from: lineData)
                // Validate base64 eagerly so a bad payload fails at load, not mid-stream.
                _ = try Self.payloadBytes(of: frame)
                frames.append(frame)
            } catch let error as ReplayError {
                throw error
            } catch {
                throw ReplayError.malformedFrame(line: index + 1, reason: String(describing: error))
            }
        }
        return frames
    }
}
