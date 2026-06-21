// Chip-family detection + flash method (SPEC §2.8). THE critical correctness
// point: the flash method branches by chip family, and a wrong binary bricks the
// board. Pure mapping; the actual flashing is an effect adapter behind a feature
// flag + HIL gate.

public enum FlashMethod: String, Sendable, Equatable {
    /// ESP32 family — esptool at chip-specific offsets.
    case esptool
    /// nRF52 / RP2040 — UF2 bootloader drag-drop.
    case uf2
    /// nRF52 DFU (alternative to UF2).
    case dfu
    case unknown
}

public enum ChipFamily: String, Sendable, Equatable, CaseIterable {
    case esp32
    case esp32s3
    case esp32s2
    case esp32c3
    case nrf52840
    case rp2040
    case unknown

    public var flashMethod: FlashMethod {
        switch self {
        case .esp32, .esp32s3, .esp32s2, .esp32c3: .esptool
        case .nrf52840, .rp2040: .uf2 // esptool does NOT apply (SPEC §2.8)
        case .unknown: .unknown
        }
    }

    /// The esptool flash offset for the app/bootloader. ESP32 boots its
    /// second-stage bootloader at 0x1000; S2/S3/C3 place it at 0x0.
    public var esptoolFlashOffset: UInt32? {
        switch self {
        case .esp32: 0x1000
        case .esp32s3, .esp32s2, .esp32c3: 0x0000
        case .nrf52840, .rp2040, .unknown: nil
        }
    }
}

public enum ChipDetection {
    /// Map a Meshtastic hardware-model name to its chip family. Order matters:
    /// the S3/S2/C3 variants are checked before the generic ESP32.
    public static func chipFamily(forHardwareModel name: String) -> ChipFamily {
        let upper = name.uppercased()
        if upper.contains("RAK4631") || upper.contains("WISMESH")
            || upper.contains("NANO_G2") || upper.contains("NRF52") { return .nrf52840 }
        if upper.contains("RP2040") || upper.contains("PICO") || upper.contains("RPI_PICO") { return .rp2040 }
        if upper.contains("S3") { return .esp32s3 }
        if upper.contains("C3") { return .esp32c3 }
        if upper.contains("S2") { return .esp32s2 }
        if upper.contains("ESP32") || upper.contains("TBEAM") || upper.contains("T_BEAM")
            || upper.contains("HELTEC") || upper.contains("TLORA") || upper.contains("XIAO") { return .esp32 }
        return .unknown
    }
}
