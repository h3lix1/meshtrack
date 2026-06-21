// Flasher port + adapters (SPEC §2.8). This whole feature is behind a feature
// flag and a hardware-in-the-loop gate. NEVER auto-flash: every flash is explicit,
// single-board, and confirmed. The verify-then-flash sequence here refuses to
// write a mismatched or unverified image.
//
// The esptool / UF2 adapters perform real I/O (process spawn / volume copy) and
// are validated on hardware (HIL), not in CI.

import Foundation

/// Proof that a human confirmed THIS specific board before a write (SPEC §2.8).
public struct FlashConfirmation: Sendable, Equatable {
    public let confirmedSerialPort: String
    public init(confirmedSerialPort: String) {
        self.confirmedSerialPort = confirmedSerialPort
    }
}

public enum FlashError: Error, Equatable, Sendable {
    case featureDisabled
    case confirmationMismatch
    case wrongFlashMethod(expected: FlashMethod, flasher: FlashMethod)
}

/// Port: writes a verified firmware image to a board. Adapters: EsptoolFlasher
/// (ESP32), UF2Flasher (nRF52/RP2040).
public protocol Flasher: Sendable {
    var method: FlashMethod { get }
    func flash(_ image: FirmwareImage, binary: [UInt8], confirmation: FlashConfirmation) async throws
}

/// Orchestrates a safe flash: feature-flag check → verify variant↔hardware →
/// verify checksum → confirm board → flash. The pure guard logic is testable; the
/// `Flasher` itself does the hardware I/O.
public struct GuardedFlasher: Sendable {
    private let flasher: any Flasher
    private let featureEnabled: Bool

    public init(flasher: any Flasher, featureEnabled: Bool = false) {
        self.flasher = flasher
        self.featureEnabled = featureEnabled
    }

    public func flash(
        _ image: FirmwareImage,
        binary: [UInt8],
        detected: ChipFamily,
        confirmation: FlashConfirmation
    ) async throws {
        guard featureEnabled else { throw FlashError.featureDisabled }
        try FirmwareVerifier.verifyCompatible(image, detected: detected)
        try FirmwareVerifier.verifyChecksum(of: binary, image: image)
        guard image.chipFamily.flashMethod == flasher.method else {
            throw FlashError.wrongFlashMethod(expected: image.chipFamily.flashMethod, flasher: flasher.method)
        }
        try await flasher.flash(image, binary: binary, confirmation: confirmation)
    }
}
