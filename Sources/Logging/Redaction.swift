// Secret redaction — the pure core of the logging wrapper (SPEC §2.5, AGENTS.md
// Safety: "redact secrets in logs, enforced by a logging wrapper").
//
// `redact(_:)` is a pure, deterministic `String -> String` transform. It runs on
// every message (and every interpolated field) before anything reaches a sink, so
// channel PSKs, admin keys, and MQTT credentials can never leak into os.Logger,
// stdout, or a log file.
//
// Design stance: **conservative**. A logger that mangles node names or hex ids is
// worse than useless (operators stop trusting it), so the matchers are tuned to
// fire on secret-*shaped* substrings only and to leave benign text — short hex ids
// like `!a1b2c3d4`, ordinary sentences, plain numbers — exactly as written. When in
// doubt we under-redact the matcher set but never the obvious secret shapes the
// spec calls out (long hex, base64 key blobs, `key=`/`psk=`/`password=`/`Authorization:`).
//
// This file imports only `Foundation` (for `NSRegularExpression`); it holds no
// mutable state and is fully `Sendable`.

import Foundation

/// The stable placeholder substituted for any redacted secret. A single constant
/// (rather than length-matched masking) keeps output deterministic and makes
/// "did this leak?" assertions trivial in tests and log review.
public let redactionPlaceholder = "‹redacted›"

/// Masks secret-shaped substrings in `message`, returning a copy safe to log.
///
/// Detects and replaces, in priority order:
/// 1. **Sensitive assignments** — `key`, `psk`, `password`, `secret`, `token`,
///    `auth`, admin/private/public-key keywords followed by `=` or `:` and a
///    value (the keyword is preserved; only the value is masked).
/// 2. **`Authorization:` headers** — the scheme is kept, the credential masked.
/// 3. **Long hex runs** (≥ 32 hex chars) — PSKs and admin keys.
/// 4. **Base64-looking key blobs** — long base64 tokens (≥ 24 chars, with the
///    structural markers — padding or mixed alphabet — that distinguish a key
///    from an ordinary word).
///
/// Pure and deterministic: same input always yields the same output, with no
/// I/O or shared state. Benign text (short `!a1b2c3d4`-style ids, prose, plain
/// integers) is returned unchanged.
///
/// - Parameter message: arbitrary text that may embed secrets.
/// - Returns: `message` with every detected secret replaced by ``redactionPlaceholder``.
public func redact(_ message: String) -> String {
    var result = message
    for matcher in Redactor.matchers {
        result = matcher.apply(to: result)
    }
    return result
}

/// Namespace holding the compiled, ordered set of redaction matchers.
///
/// The regular expressions are compiled once at first use and reused for the
/// process lifetime. `NSRegularExpression` is thread-safe for matching, so the
/// shared instances are safe to use from any task; the array is exposed as a
/// `let` and never mutated.
enum Redactor {
    /// A single named regex-based redaction rule.
    struct Matcher {
        let name: String
        let regex: NSRegularExpression
        /// Replacement template. `$0` is the whole match; capture groups `$1`,
        /// `$2`, … let a rule preserve a keyword/prefix and mask only the value.
        let template: String

        func apply(to input: String) -> String {
            let range = NSRange(input.startIndex ..< input.endIndex, in: input)
            return regex.stringByReplacingMatches(
                in: input,
                options: [],
                range: range,
                withTemplate: template
            )
        }
    }

    /// Compile a matcher, trapping only on a programmer error in a literal
    /// pattern below (never on user input). Patterns are unit-tested, so a bad
    /// pattern fails fast in CI rather than silently disabling redaction.
    private static func make(
        _ name: String,
        _ pattern: String,
        options: NSRegularExpression.Options = [.caseInsensitive],
        template: String
    ) -> Matcher {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            preconditionFailure("Redaction pattern '\(name)' failed to compile: \(pattern)")
        }
        return Matcher(name: name, regex: regex, template: template)
    }

    /// One base64 *body* symbol (URL-safe `-`/`_` variants included; padding `=`
    /// is matched separately so it can only appear as a trailing marker).
    private static let base64Word = "[A-Za-z0-9+/_-]"

    /// A left boundary for a base64 token: start-of-string or a character that is
    /// not itself a base64 body symbol. Avoids `\b`, which is unreliable next to
    /// the non-word symbols `+` and `/`. Used as a non-capturing lookbehind.
    private static let base64Start = "(?<![A-Za-z0-9+/=_-])"

    /// A right boundary: end-of-string or a non-base64, non-`=` character.
    private static let base64End = "(?![A-Za-z0-9+/=_-])"

    /// Ordered matchers. **Order matters**: assignment/header rules run first so a
    /// `psk=<hex>` value is masked once as a unit (keyword preserved), before the
    /// standalone hex/base64 rules would otherwise also fire inside it.
    static let matchers: [Matcher] = [
        // 1. `Authorization` credential (HTTP-style). Runs BEFORE the generic
        //    assignment rule so the `Bearer`/`Basic` scheme word is preserved and
        //    only the credential after it is masked. Handles both the header form
        //    `Authorization: Bearer <cred>` and `authorization=<cred>`.
        make(
            "authorization",
            #"\b(authorization\s*[=:]\s*)((?:bearer|basic|digest|token)\s+)?[^\s,;}"']+"#,
            template: "$1$2\(placeholderTemplate)"
        ),

        // 2. Sensitive `key = value` / `key: value` assignments. The keyword and
        //    its delimiter are captured ($1$2) and preserved; the value — a run of
        //    non-space, non-delimiter characters, optionally quoted — is masked.
        //    Keyword set covers PSKs, passwords, tokens, and admin/PKI key names.
        //    `(?![\w-])` after the keyword stops `key` matching inside `keyboard`
        //    and `pwd` inside `pwdgen`, and (with rule 1 ahead) keeps this from
        //    re-touching an `authorization` line.
        make(
            "assignment",
            #"\b(psk|pre[_-]?shared[_-]?key|password|passwd|pwd|secret|api[_-]?key|"#
                + #"access[_-]?key|admin[_-]?key|private[_-]?key|pub(?:lic)?[_-]?key|"#
                + #"token|credential|key)(?![\w-])"#
                + #"(\s*[=:]\s*)"#
                + #"(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^\s,;}"']+)"#,
            template: "$1$2\(placeholderTemplate)"
        ),

        // 3. Long contiguous hex runs (≥ 32 hex digits) — PSKs / admin keys, with
        //    or without an `0x` prefix. The `\b` floors and the 32-char minimum
        //    keep short hex node ids (`!a1b2c3d4`, 8 chars) untouched.
        make(
            "hex-run",
            #"\b(?:0[xX])?[0-9a-fA-F]{32,}\b"#,
            options: [],
            template: placeholderTemplate
        ),

        // 4. Base64-looking key blobs. Conservative: require ≥ 24 base64 symbols
        //    AND a structural marker that ordinary prose lacks — either `=`
        //    padding, a `+`/`/` symbol, or a mix of upper, lower, and digit.
        //    A bare 24-letter lowercase word will not match (no marker), so node
        //    names and sentences survive untouched.
        make(
            "base64-padded",
            "\(base64Start)\(base64Word){23,}={1,2}\(base64End)",
            options: [],
            template: placeholderTemplate
        ),
        make(
            "base64-symbols",
            "\(base64Start)(?=\(base64Word)*[+/])\(base64Word){24,}\(base64End)",
            options: [],
            template: placeholderTemplate
        ),
        make(
            "base64-mixed",
            mixedAlphabetBase64Pattern,
            options: [],
            template: placeholderTemplate
        )
    ]

    /// `NSRegularExpression` templates treat `$` specially, but our placeholder is
    /// plain text — still, escape defensively so a future placeholder containing
    /// `$`/`\` cannot corrupt the template.
    private static let placeholderTemplate: String = {
        var escaped = ""
        for character in redactionPlaceholder {
            if character == "$" || character == "\\" { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped
    }()

    /// A ≥ 24-symbol base64 token that contains at least one upper, one lower, and
    /// one digit. The lookaheads enforce the "mixed alphabet" marker so plain
    /// lowercase words (however long), all-caps constants, and digit runs are
    /// never matched — only key-shaped blobs that mix all three.
    private static let mixedAlphabetBase64Pattern =
        "\(base64Start)(?=\(base64Word)*[a-z])(?=\(base64Word)*[A-Z])"
            + "(?=\(base64Word)*[0-9])\(base64Word){24,}\(base64End)"
}
