// Meshtastic node-id hex formatting — the single source of truth.
//
// A Meshtastic node id renders as `!aabbccdd`: a `!` prefix followed by the
// 32-bit node number as 8 lowercase, zero-padded hex digits. The conventional
// "short id" is the low 16 bits as 4 lowercase, zero-padded hex digits (e.g.
// `c3d4`). This was copy-pasted across ~15 view models and views as
// `String(format: "%08x"/"%04x", ...)`; that's Foundation and is banned in
// Domain, so we format with the standard library only. `String(_:radix:)` is
// already lowercase; we left-pad with "0" to the required width. The output is
// byte-for-byte identical to the old `String(format:)` results.

public enum NodeID {
    /// The full `!aabbccdd` Meshtastic node id: `!` + 8 lowercase zero-padded
    /// hex digits. Pass `UInt32(truncatingIfNeeded:)` of an `Int64`/`Int` node
    /// number when needed.
    public static func hex(_ value: UInt32) -> String {
        "!" + paddedHex(value, width: 8)
    }

    /// The 4-hex "short id" (the low 16 bits, e.g. `c3d4`) — no prefix.
    public static func shortHex(_ value: UInt32) -> String {
        paddedHex(value & 0xFFFF, width: 4)
    }

    /// Lowercase hex of `value`, left-padded with "0" to at least `width` digits.
    /// Matches `String(format: "%0\(width)x", value)` with stdlib only.
    private static func paddedHex(_ value: UInt32, width: Int) -> String {
        let digits = String(value, radix: 16)
        if digits.count >= width { return digits }
        return String(repeating: "0", count: width - digits.count) + digits
    }
}
