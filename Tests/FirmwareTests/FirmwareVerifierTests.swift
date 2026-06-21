@testable import Firmware
import Testing

@Suite("Firmware verification (SPEC §2.8)")
struct FirmwareVerifierTests {
    private let binary: [UInt8] = [0x01, 0x02, 0x03]
    private var image: FirmwareImage {
        FirmwareImage(
            variant: "tbeam",
            version: "2.5",
            chipFamily: .esp32,
            sha256: FirmwareVerifier.sha256Hex(binary)
        )
    }

    @Test
    func `a matching chip passes; a mismatch or unknown chip throws`() throws {
        try FirmwareVerifier.verifyCompatible(image, detected: .esp32) // no throw
        #expect(throws: FirmwareError.self) {
            try FirmwareVerifier.verifyCompatible(image, detected: .nrf52840)
        }
        #expect(throws: FirmwareError.unknownChip) {
            try FirmwareVerifier.verifyCompatible(image, detected: .unknown)
        }
    }

    @Test
    func `checksum verification matches the pinned hash`() throws {
        try FirmwareVerifier.verifyChecksum(of: binary, image: image) // no throw
        #expect(throws: FirmwareError.self) {
            try FirmwareVerifier.verifyChecksum(of: [0x01, 0x02, 0x04], image: image)
        }
    }

    @Test
    func `sha256 of empty input is the known digest`() {
        #expect(FirmwareVerifier.sha256Hex([])
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }
}
