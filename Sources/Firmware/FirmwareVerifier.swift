// Firmware image pinning + verification (SPEC §2.8). Pin + checksum every binary,
// and verify the variant matches the detected hardware BEFORE writing — a wrong
// binary bricks the board.

import CryptoKit
import Foundation

/// A pinned firmware image: which chip it targets + its expected SHA-256.
public struct FirmwareImage: Sendable, Equatable {
    public let variant: String
    public let version: String
    public let chipFamily: ChipFamily
    /// Pinned SHA-256 of the binary, lowercase hex.
    public let sha256: String

    public init(variant: String, version: String, chipFamily: ChipFamily, sha256: String) {
        self.variant = variant
        self.version = version
        self.chipFamily = chipFamily
        self.sha256 = sha256
    }
}

public enum FirmwareError: Error, Equatable, Sendable {
    case variantHardwareMismatch(imageChip: ChipFamily, detected: ChipFamily)
    case checksumMismatch(expected: String, actual: String)
    case unknownChip
}

public enum FirmwareVerifier {
    /// Verify the image targets the detected hardware. Throws on mismatch or an
    /// unidentified chip — never flash a binary we can't match (SPEC §2.8).
    public static func verifyCompatible(_ image: FirmwareImage, detected: ChipFamily) throws {
        guard detected != .unknown else { throw FirmwareError.unknownChip }
        guard image.chipFamily == detected else {
            throw FirmwareError.variantHardwareMismatch(imageChip: image.chipFamily, detected: detected)
        }
    }

    /// Verify the binary's SHA-256 matches the image's pinned checksum.
    public static func verifyChecksum(of binary: [UInt8], image: FirmwareImage) throws {
        let actual = sha256Hex(binary)
        guard actual.caseInsensitiveCompare(image.sha256) == .orderedSame else {
            throw FirmwareError.checksumMismatch(expected: image.sha256, actual: actual)
        }
    }

    public static func sha256Hex(_ binary: [UInt8]) -> String {
        SHA256.hash(data: Data(binary)).map { String(format: "%02x", $0) }.joined()
    }
}
