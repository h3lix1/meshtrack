@testable import Firmware
import Testing

@Suite("GuardedFlasher safety — never auto-flash (SPEC §2.8)")
struct GuardedFlasherTests {
    private actor RecordingFlasher: Flasher {
        let method: FlashMethod
        private(set) var flashed = false
        init(method: FlashMethod) {
            self.method = method
        }

        func flash(_: FirmwareImage, binary _: [UInt8], confirmation _: FlashConfirmation) {
            flashed = true
        }
    }

    private let binary: [UInt8] = [0xAA, 0xBB]
    private let confirm = FlashConfirmation(confirmedSerialPort: "/dev/cu.usbmodem3101")
    private func image(_ chip: ChipFamily, sha: String? = nil) -> FirmwareImage {
        FirmwareImage(
            variant: "v",
            version: "1",
            chipFamily: chip,
            sha256: sha ?? FirmwareVerifier.sha256Hex(binary)
        )
    }

    @Test
    func `a disabled feature flag refuses to flash`() async {
        let flasher = RecordingFlasher(method: .esptool)
        let guarded = GuardedFlasher(flasher: flasher, featureEnabled: false)
        await #expect(throws: FlashError.featureDisabled) {
            try await guarded.flash(image(.esp32), binary: binary, detected: .esp32, confirmation: confirm)
        }
        let flashed = await flasher.flashed
        #expect(flashed == false)
    }

    @Test
    func `a verified, confirmed flash on matching hardware proceeds`() async throws {
        let flasher = RecordingFlasher(method: .esptool)
        let guarded = GuardedFlasher(flasher: flasher, featureEnabled: true)
        try await guarded.flash(image(.esp32), binary: binary, detected: .esp32, confirmation: confirm)
        let flashed = await flasher.flashed
        #expect(flashed)
    }

    @Test
    func `a chip mismatch refuses to flash (wrong binary bricks the board)`() async {
        let flasher = RecordingFlasher(method: .esptool)
        let guarded = GuardedFlasher(flasher: flasher, featureEnabled: true)
        await #expect(throws: FirmwareError.self) {
            try await guarded.flash(image(.nrf52840), binary: binary, detected: .esp32, confirmation: confirm)
        }
        let flashed = await flasher.flashed
        #expect(flashed == false)
    }

    @Test
    func `a checksum mismatch refuses to flash`() async {
        let flasher = RecordingFlasher(method: .esptool)
        let guarded = GuardedFlasher(flasher: flasher, featureEnabled: true)
        await #expect(throws: FirmwareError.self) {
            try await guarded.flash(
                image(.esp32, sha: "deadbeef"),
                binary: binary,
                detected: .esp32,
                confirmation: confirm
            )
        }
        let flashed = await flasher.flashed
        #expect(flashed == false)
    }

    @Test
    func `a flasher whose method doesn't match the chip is rejected`() async {
        let flasher = RecordingFlasher(method: .uf2) // UF2 flasher for an esptool chip
        let guarded = GuardedFlasher(flasher: flasher, featureEnabled: true)
        await #expect(throws: FlashError.self) {
            try await guarded.flash(image(.esp32), binary: binary, detected: .esp32, confirmation: confirm)
        }
    }
}
