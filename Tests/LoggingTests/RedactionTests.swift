@testable import Logging
import Testing

/// The redaction core is the most-tested deliverable: it is the single guarantee
/// that secrets never leave the process. These tests prove it masks the secret
/// *shapes* the spec calls out while leaving benign text untouched.
@Suite("redact() — masks secrets, spares benign text")
struct RedactionTests {
    /// A representative Meshtastic-style 256-bit PSK as a 64-char hex string.
    static let pskHex = "1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b"
    /// A 256-bit key rendered as padded base64 (44 chars, trailing `=`).
    static let keyBase64 = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="

    // MARK: - Secrets that MUST be masked

    @Test func `masks a long PSK hex run`() {
        let redacted = redact("loaded channel psk \(Self.pskHex) for LongFast")
        #expect(!redacted.contains(Self.pskHex))
        #expect(redacted.contains(redactionPlaceholder))
        #expect(redacted.hasPrefix("loaded channel psk "))
        #expect(redacted.hasSuffix(" for LongFast"))
    }

    @Test func `masks a 0x-prefixed hex key`() {
        let redacted = redact("admin key 0x\(Self.pskHex)")
        #expect(!redacted.contains(Self.pskHex))
        #expect(redacted.contains(redactionPlaceholder))
    }

    @Test func `masks a base64 key blob`() {
        let redacted = redact("derived session key \(Self.keyBase64)")
        #expect(!redacted.contains(Self.keyBase64))
        #expect(redacted.contains(redactionPlaceholder))
    }

    @Test func `masks psk= assignment value`() {
        let redacted = redact("config psk=hunter2supersecretvalue applied")
        #expect(!redacted.contains("hunter2supersecretvalue"))
        #expect(redacted.contains("psk="))
        #expect(redacted.contains(redactionPlaceholder))
    }

    @Test func `masks password= assignment value`() {
        let redacted = redact("mqtt password=Tr0ub4dor&3 connecting")
        #expect(!redacted.contains("Tr0ub4dor&3"))
        #expect(redacted.contains("password="))
        #expect(redacted.contains("connecting"))
        #expect(redacted.contains(redactionPlaceholder))
    }

    @Test func `masks colon-delimited secret assignment`() {
        let redacted = redact("secret: myLittleSecretToken")
        #expect(!redacted.contains("myLittleSecretToken"))
        #expect(redacted.contains(redactionPlaceholder))
    }

    @Test func `masks quoted assignment value including spaces`() {
        let redacted = redact(#"password="correct horse battery staple""#)
        #expect(!redacted.contains("correct horse battery staple"))
        #expect(redacted.contains("password="))
        #expect(redacted.contains(redactionPlaceholder))
    }

    @Test func `masks token assignment`() {
        let redacted = redact("ntfy token=tk_abcdef0123456789abcdef")
        #expect(!redacted.contains("tk_abcdef0123456789abcdef"))
        #expect(redacted.contains(redactionPlaceholder))
    }

    @Test func `masks api_key assignment`() {
        // Synthetic value (deliberately not AWS/GitHub/etc. shaped) so the test
        // exercises the assignment matcher without tripping the repo secret scan.
        let redacted = redact("webhook api_key=wh-LIVE-7f0c9a3b21e4d6 done")
        #expect(!redacted.contains("wh-LIVE-7f0c9a3b21e4d6"))
        #expect(redacted.contains(redactionPlaceholder))
        #expect(redacted.contains("done"))
    }

    @Test func `masks Authorization bearer credential and keeps scheme`() {
        let redacted = redact("GET /api Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payload.sig")
        #expect(!redacted.contains("eyJhbGciOiJIUzI1NiJ9.payload.sig"))
        #expect(redacted.contains("Bearer"))
        #expect(redacted.contains(redactionPlaceholder))
    }

    @Test func `masks Authorization basic credential`() {
        let redacted = redact("Authorization: Basic dXNlcjpwYXNzd29yZA==")
        #expect(!redacted.contains("dXNlcjpwYXNzd29yZA=="))
        #expect(redacted.contains(redactionPlaceholder))
    }

    @Test func `masks admin_key assignment`() {
        let redacted = redact("installed admin_key=\(Self.keyBase64)")
        #expect(!redacted.contains(Self.keyBase64))
        #expect(redacted.contains(redactionPlaceholder))
    }

    @Test func `masks every secret when several appear in one line`() {
        let line = "psk=topsecretvalue123 and key \(Self.pskHex) and password=swordfish"
        let redacted = redact(line)
        #expect(!redacted.contains("topsecretvalue123"))
        #expect(!redacted.contains(Self.pskHex))
        #expect(!redacted.contains("swordfish"))
    }

    @Test func `redaction is idempotent`() {
        let once = redact("psk=\(Self.pskHex)")
        let twice = redact(once)
        #expect(once == twice)
    }

    // MARK: - Benign text that MUST survive unchanged

    @Test func `leaves a short node hex id untouched`() {
        let input = "node !a1b2c3d4 heard via gateway !ff00ab12"
        #expect(redact(input) == input)
    }

    @Test func `leaves an ordinary sentence untouched`() {
        let input = "The collector reconnected to the broker after 3 retries."
        #expect(redact(input) == input)
    }

    @Test func `leaves plain numbers untouched`() {
        let input = "battery 87% voltage 4.01V uptime 360123 channel_util 12.5"
        #expect(redact(input) == input)
    }

    @Test func `leaves node names and DSL-rendered names untouched`() {
        let input = "renamed baymesh-A123 (short BM01) class=fixed"
        // `class=fixed` is not a secret keyword, so the value stays.
        #expect(redact(input) == input)
    }

    @Test func `does not mask a keyword embedded in a larger word`() {
        // "keyboard" contains "key" and "monkey" ends in "key"; neither is a
        // secret assignment, and there is no `=`/`:` value, so nothing changes.
        let input = "keyboard shortcut for the monkey dashboard"
        #expect(redact(input) == input)
    }

    @Test func `leaves a moderate hex id below the threshold untouched`() {
        // 24 hex chars — below the 32-char PSK floor; e.g. a short correlation id.
        let input = "trace ab0123ab0123ab0123ab0123 ok"
        #expect(redact(input) == input)
    }

    @Test func `leaves an all-lowercase long word untouched`() {
        // 30 lowercase letters: no base64 marker (no padding, symbol, or mixed
        // case+digit) so the conservative base64 matcher must not fire.
        let input = "supercalifragilisticexpialidocious indeed"
        #expect(redact(input) == input)
    }

    @Test func `leaves an empty string untouched`() {
        #expect(redact("") == "")
    }

    @Test func `leaves a UUID untouched`() {
        // A hyphenated UUID is not a contiguous 32-hex run, and not a secret.
        let input = "request 550e8400-e29b-41d4-a716-446655440000 done"
        #expect(redact(input) == input)
    }

    // MARK: - Placeholder contract

    @Test func `uses the documented stable placeholder`() {
        #expect(redactionPlaceholder == "‹redacted›")
        #expect(redact("psk=\(Self.pskHex)").contains("‹redacted›"))
    }
}
