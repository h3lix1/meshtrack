@testable import App
import Testing

@Suite("DefaultChannelDecodePolicy + gate (default-PSK fallback gating, Finding 16)")
struct DefaultChannelGateTests {
    @Test
    func `default key falls back only while present and not tombstoned`() {
        #expect(DefaultChannelDecodePolicy.defaultEnabled(registryContainsDefault: true, tombstoned: false))
        // Tombstoned ⇒ withheld even if still present in a stale registry read.
        #expect(!DefaultChannelDecodePolicy.defaultEnabled(registryContainsDefault: true, tombstoned: true))
        // Absent ⇒ withheld (operator removed it; nothing to fall back to).
        #expect(!DefaultChannelDecodePolicy.defaultEnabled(registryContainsDefault: false, tombstoned: false))
        #expect(!DefaultChannelDecodePolicy.defaultEnabled(registryContainsDefault: false, tombstoned: true))
    }

    @Test
    func `gate is enabled by default and reflects set()`() {
        let gate = DefaultChannelGate()
        #expect(gate.isEnabled())
        gate.set(false)
        #expect(!gate.isEnabled())
        gate.set(true)
        #expect(gate.isEnabled())
    }

    @Test
    func `gate honours an explicit initial value`() {
        #expect(!DefaultChannelGate(enabled: false).isEnabled())
    }
}
