@testable import Provisioning
import Testing

@Suite("NamingDSL renderer + byte limits (SPEC §2.1)")
struct NamingDSLTests {
    private let context = NamingContext(
        id: "!aabbA123", shortName: "baymesh", longName: "Bay Mesh Node", region: "US"
    )

    @Test
    func `renders tokens with end-slicing (the spec example)`() throws {
        #expect(try NamingDSL.render("{shortName}-{id[-4:]}", context: context) == "baymesh-A123")
    }

    @Test
    func `slices support [:n] and [a:b]`() throws {
        #expect(try NamingDSL.render("{shortName[:3]}", context: context) == "bay")
        #expect(try NamingDSL.render("{shortName[1:3]}", context: context) == "ay")
    }

    @Test
    func `long name renders within the 39-byte limit`() throws {
        #expect(try NamingDSL.renderLongName("{shortName}-{id[-4:]}", context: context) == "baymesh-A123")
    }

    @Test
    func `short name within 4 bytes is accepted`() throws {
        #expect(try NamingDSL.renderShortName("{id[-4:]}", context: context) == "A123")
    }

    @Test
    func `a short name over 4 bytes is rejected`() {
        #expect(throws: NameError.shortNameTooLong(bytes: 7, max: 4)) {
            _ = try NamingDSL.renderShortName("{shortName}", context: context)
        }
    }

    @Test
    func `byte limits count UTF-8 bytes, not characters`() throws {
        // 😀 is one character but four UTF-8 bytes — exactly the limit.
        #expect(try NamingDSL
            .renderShortName("{shortName}", context: NamingContext(id: "x", shortName: "😀")) == "😀")
        // 😀x is five bytes — over.
        #expect(throws: NameError.self) {
            _ = try NamingDSL.renderShortName("{shortName}", context: NamingContext(id: "x", shortName: "😀x"))
        }
    }

    @Test
    func `an unknown token is rejected`() {
        #expect(throws: NameError.unknownToken("nope")) {
            _ = try NamingDSL.render("{nope}", context: context)
        }
    }

    @Test
    func `an unterminated token is rejected`() {
        #expect(throws: NameError.unterminatedToken) {
            _ = try NamingDSL.render("{shortName", context: context)
        }
    }

    @Test
    func `a template that renders empty is rejected for a name`() {
        #expect(throws: NameError.empty) {
            _ = try NamingDSL.renderShortName("{shortName}", context: NamingContext(id: "x"))
        }
    }
}
