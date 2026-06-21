@testable import Firmware
import Testing

@Suite("Chip-family detection + flash method (SPEC §2.8)")
struct ChipDetectionTests {
    @Test
    func `hardware models map to chip families`() {
        #expect(ChipDetection.chipFamily(forHardwareModel: "TBEAM") == .esp32)
        #expect(ChipDetection.chipFamily(forHardwareModel: "TLORA_V2_1_1P6") == .esp32)
        #expect(ChipDetection.chipFamily(forHardwareModel: "XIAO_ESP32S3") == .esp32s3)
        #expect(ChipDetection.chipFamily(forHardwareModel: "HELTEC_HT62_ESP32C3") == .esp32c3)
        #expect(ChipDetection.chipFamily(forHardwareModel: "RAK4631") == .nrf52840)
        #expect(ChipDetection.chipFamily(forHardwareModel: "RP2040_LORA") == .rp2040)
        #expect(ChipDetection.chipFamily(forHardwareModel: "PRIVATE_HW") == .unknown)
    }

    @Test
    func `flash method branches by chip — esptool never applies to nRF52/RP2040`() {
        #expect(ChipFamily.esp32.flashMethod == .esptool)
        #expect(ChipFamily.esp32c3.flashMethod == .esptool)
        #expect(ChipFamily.nrf52840.flashMethod == .uf2)
        #expect(ChipFamily.rp2040.flashMethod == .uf2)
    }

    @Test
    func `esptool offsets are chip-specific`() {
        #expect(ChipFamily.esp32.esptoolFlashOffset == 0x1000)
        #expect(ChipFamily.esp32s3.esptoolFlashOffset == 0x0000)
        #expect(ChipFamily.nrf52840.esptoolFlashOffset == nil)
    }
}
