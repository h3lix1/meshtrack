// AdminConfigRegistry — the declarative field table that powers
// `AdminMessageMapping` (SPEC §2.7).
//
// Every provisionable field is one `FieldSpec`: its `AdminConfigField`, the
// `ConfigSlot` it lives in, and a value codec (string→protobuf on apply,
// protobuf→string on read-back). The apply / read-back / verify pipeline is
// generic over `AdminConfigField.registry`, so extending the surface to the rest
// of the proto is purely additive — append a `FieldSpec` here, nothing else
// changes. This file is PURE (no I/O), exactly like the mapping it serves.
//
// `FieldSpec` stores type-erased closures so one homogeneous `[FieldSpec]` can hold
// fields that target different protobuf sub-messages. The `make…` factories below
// keep each entry a single readable line keyed off a Swift key-path, so a reviewer
// sees field → key-path → string-form at a glance.

import Foundation
import MeshProtos

/// One field's slot + value codec. Type-erased over the concrete protobuf so the
/// registry is a single homogeneous array. The `encode…`/`decode…` closures are
/// only meaningful for the matching `slot`; the others are no-ops/nil.
struct FieldSpec {
    let field: AdminConfigField
    let slot: ConfigSlot

    // The codec closures are `var` so the `make…` factories can set just the
    // slot-relevant ones over a `stub`'s inert defaults (the value type is built
    // once at registry init and never mutated again).

    /// Throw if `value` can't be parsed for this field (the confirm-time guard).
    var validate: @Sendable (String) throws -> Void

    /// Mutate the matching sub-message of a `Config` (slot == .config only).
    var encodeConfig: @Sendable (String, inout Config) throws -> Void
    /// Read this field's value out of a `Config` (nil if the config isn't this
    /// field's sub-message). Drives read-back.
    var decodeConfig: @Sendable (Config) -> String?

    /// Mutate the matching sub-message of a `ModuleConfig` (slot == .module only).
    var encodeModule: @Sendable (String, inout ModuleConfig) throws -> Void
    var decodeModule: @Sendable (ModuleConfig) -> String?

    /// Mutate a `User` (slot == .owner only).
    var encodeOwner: @Sendable (String, inout User) throws -> Void
    var decodeOwner: @Sendable (User) -> String?

    /// Mutate a primary `Channel` (slot == .channel only).
    var encodeChannel: @Sendable (String, inout Channel) throws -> Void
    var decodeChannel: @Sendable (Channel) -> String?

    /// Whether `config`'s payload is this field's sub-message (so read-back only
    /// asks the right field).
    var matchesConfig: @Sendable (Config) -> Bool
    /// Whether `module`'s payload is this field's sub-message.
    var matchesModule: @Sendable (ModuleConfig) -> Bool
}

extension FieldSpec {
    /// A spec stub with every closure inert; the `make…` factories override the
    /// slot-relevant ones. Keeps each factory from re-listing the no-ops.
    static func stub(
        _ field: AdminConfigField,
        slot: ConfigSlot,
        validate: @escaping @Sendable (String) throws -> Void
    ) -> FieldSpec {
        FieldSpec(
            field: field,
            slot: slot,
            validate: validate,
            encodeConfig: { _, _ in },
            decodeConfig: { _ in nil },
            encodeModule: { _, _ in },
            decodeModule: { _ in nil },
            encodeOwner: { _, _ in },
            decodeOwner: { _ in nil },
            encodeChannel: { _, _ in },
            decodeChannel: { _ in nil },
            matchesConfig: { _ in false },
            matchesModule: { _ in false }
        )
    }
}

// MARK: - Value parsers (string ↔ scalar)

/// Pure parsers shared by every field codec. They throw the typed
/// `AdminMappingError` rather than force-unwrapping a bad value.
enum ValueParse {
    static func bool(_ raw: String, field: AdminConfigField) throws -> Bool {
        switch raw.lowercased() {
        case "true", "1", "yes", "on": true
        case "false", "0", "no", "off": false
        default: throw AdminMappingError.invalidBool(field: field.rawValue, value: raw)
        }
    }

    static func uint32(_ raw: String, field: AdminConfigField) throws -> UInt32 {
        guard let value = UInt32(raw) else {
            throw AdminMappingError.invalidNumber(field: field.rawValue, value: raw)
        }
        return value
    }

    static func int32(_ raw: String, field: AdminConfigField) throws -> Int32 {
        guard let value = Int32(raw) else {
            throw AdminMappingError.invalidNumber(field: field.rawValue, value: raw)
        }
        return value
    }

    static func string(_ raw: String) -> String {
        raw
    }
}

// MARK: - Lenses (bundle extract/embed/empty so a factory stays ≤ 5 params)

/// A focus into one `Config` sub-message of type `Sub`: read it back out, write it
/// in, and make a fresh one. Bundling the three keeps the field factories small and
/// each table row a single line.
struct ConfigLens<Sub> {
    let extract: @Sendable (Config) -> Sub?
    let embed: @Sendable (Sub, inout Config) -> Void
    let empty: @Sendable () -> Sub
}

/// A focus into one `ModuleConfig` sub-message of type `Sub`.
struct ModuleLens<Sub> {
    let extract: @Sendable (ModuleConfig) -> Sub?
    let embed: @Sendable (Sub, inout ModuleConfig) -> Void
    let empty: @Sendable () -> Sub
}

// MARK: - FieldSpec factories (one per scalar shape × slot)

extension FieldSpec {
    // ── Config sub-message factories ─────────────────────────────────────────

    static func configBool<Sub>(
        _ field: AdminConfigField,
        _ type: AdminMessage.ConfigType,
        _ lens: ConfigLens<Sub>,
        _ path: WritableKeyPath<Sub, Bool> & Sendable
    ) -> FieldSpec {
        var spec = stub(field, slot: .config(type)) { _ = try ValueParse.bool($0, field: field) }
        spec.encodeConfig = { raw, config in
            var sub = lens.extract(config) ?? lens.empty()
            sub[keyPath: path] = try ValueParse.bool(raw, field: field)
            lens.embed(sub, &config)
        }
        spec.decodeConfig = { config in lens.extract(config).map { boolString($0[keyPath: path]) } }
        spec.matchesConfig = { lens.extract($0) != nil }
        return spec
    }

    static func configUInt32<Sub>(
        _ field: AdminConfigField,
        _ type: AdminMessage.ConfigType,
        _ lens: ConfigLens<Sub>,
        _ path: WritableKeyPath<Sub, UInt32> & Sendable
    ) -> FieldSpec {
        var spec = stub(field, slot: .config(type)) { _ = try ValueParse.uint32($0, field: field) }
        spec.encodeConfig = { raw, config in
            var sub = lens.extract(config) ?? lens.empty()
            sub[keyPath: path] = try ValueParse.uint32(raw, field: field)
            lens.embed(sub, &config)
        }
        spec.decodeConfig = { config in lens.extract(config).map { String($0[keyPath: path]) } }
        spec.matchesConfig = { lens.extract($0) != nil }
        return spec
    }

    static func configInt32<Sub>(
        _ field: AdminConfigField,
        _ type: AdminMessage.ConfigType,
        _ lens: ConfigLens<Sub>,
        _ path: WritableKeyPath<Sub, Int32> & Sendable
    ) -> FieldSpec {
        var spec = stub(field, slot: .config(type)) { _ = try ValueParse.int32($0, field: field) }
        spec.encodeConfig = { raw, config in
            var sub = lens.extract(config) ?? lens.empty()
            sub[keyPath: path] = try ValueParse.int32(raw, field: field)
            lens.embed(sub, &config)
        }
        spec.decodeConfig = { config in lens.extract(config).map { String($0[keyPath: path]) } }
        spec.matchesConfig = { lens.extract($0) != nil }
        return spec
    }

    static func configString<Sub>(
        _ field: AdminConfigField,
        _ type: AdminMessage.ConfigType,
        _ lens: ConfigLens<Sub>,
        _ path: WritableKeyPath<Sub, String> & Sendable
    ) -> FieldSpec {
        var spec = stub(field, slot: .config(type)) { _ in }
        spec.encodeConfig = { raw, config in
            var sub = lens.extract(config) ?? lens.empty()
            sub[keyPath: path] = raw
            lens.embed(sub, &config)
        }
        // Empty strings are real values here (e.g. clearing an SSID); report them.
        spec.decodeConfig = { config in lens.extract(config).map { $0[keyPath: path] } }
        spec.matchesConfig = { lens.extract($0) != nil }
        return spec
    }

    static func configEnum<Sub, E: RawRepresentable & Hashable & Sendable>(
        _ field: AdminConfigField,
        _ type: AdminMessage.ConfigType,
        _ lens: ConfigLens<Sub>,
        _ path: WritableKeyPath<Sub, E> & Sendable,
        codec: EnumCodec<E>,
        error: (@Sendable (String) -> AdminMappingError)? = nil
    ) -> FieldSpec where E.RawValue == Int {
        // Region/role keep their dedicated error cases (existing API contract); every
        // other enum field reports the generic `unknownEnum`.
        let makeError = error ?? { AdminMappingError.unknownEnum(field: field.rawValue, value: $0) }
        var spec = stub(field, slot: .config(type)) {
            guard codec.byName[AdminMessageMapping.normalize($0)] != nil else {
                throw makeError($0)
            }
        }
        spec.encodeConfig = { raw, config in
            var sub = lens.extract(config) ?? lens.empty()
            sub[keyPath: path] = codec.byName[AdminMessageMapping.normalize(raw)] ?? codec.fallback
            lens.embed(sub, &config)
        }
        spec.decodeConfig = { config in
            lens.extract(config).map { codec.byCode[$0[keyPath: path]] ?? codec.fallbackName }
        }
        spec.matchesConfig = { lens.extract($0) != nil }
        return spec
    }

    // ── ModuleConfig sub-message factories ───────────────────────────────────

    static func moduleBool<Sub>(
        _ field: AdminConfigField,
        _ type: AdminMessage.ModuleConfigType,
        _ lens: ModuleLens<Sub>,
        _ path: WritableKeyPath<Sub, Bool> & Sendable
    ) -> FieldSpec {
        var spec = stub(field, slot: .module(type)) { _ = try ValueParse.bool($0, field: field) }
        spec.encodeModule = { raw, module in
            var sub = lens.extract(module) ?? lens.empty()
            sub[keyPath: path] = try ValueParse.bool(raw, field: field)
            lens.embed(sub, &module)
        }
        spec.decodeModule = { module in lens.extract(module).map { boolString($0[keyPath: path]) } }
        spec.matchesModule = { lens.extract($0) != nil }
        return spec
    }

    static func moduleUInt32<Sub>(
        _ field: AdminConfigField,
        _ type: AdminMessage.ModuleConfigType,
        _ lens: ModuleLens<Sub>,
        _ path: WritableKeyPath<Sub, UInt32> & Sendable
    ) -> FieldSpec {
        var spec = stub(field, slot: .module(type)) { _ = try ValueParse.uint32($0, field: field) }
        spec.encodeModule = { raw, module in
            var sub = lens.extract(module) ?? lens.empty()
            sub[keyPath: path] = try ValueParse.uint32(raw, field: field)
            lens.embed(sub, &module)
        }
        spec.decodeModule = { module in lens.extract(module).map { String($0[keyPath: path]) } }
        spec.matchesModule = { lens.extract($0) != nil }
        return spec
    }

    static func moduleString<Sub>(
        _ field: AdminConfigField,
        _ type: AdminMessage.ModuleConfigType,
        _ lens: ModuleLens<Sub>,
        _ path: WritableKeyPath<Sub, String> & Sendable
    ) -> FieldSpec {
        var spec = stub(field, slot: .module(type)) { _ in }
        spec.encodeModule = { raw, module in
            var sub = lens.extract(module) ?? lens.empty()
            sub[keyPath: path] = raw
            lens.embed(sub, &module)
        }
        spec.decodeModule = { module in lens.extract(module).map { $0[keyPath: path] } }
        spec.matchesModule = { lens.extract($0) != nil }
        return spec
    }

    // ── Owner factory ────────────────────────────────────────────────────────

    /// An owner (`User`) string field. Empty values are skipped on read-back (an
    /// empty owner field is "absent", not a meaningful current value).
    static func ownerString(
        _ field: AdminConfigField,
        _ path: WritableKeyPath<User, String> & Sendable
    ) -> FieldSpec {
        var spec = stub(field, slot: .owner) { _ in }
        spec.encodeOwner = { raw, owner in owner[keyPath: path] = raw }
        spec.decodeOwner = { owner in
            let value = owner[keyPath: path]
            return value.isEmpty ? nil : value
        }
        return spec
    }
}

// MARK: - boolString (the canonical Bool string form)

/// Snapshot Bools render as "true"/"false" so the diff text round-trips stably.
func boolString(_ value: Bool) -> String {
    value ? "true" : "false"
}
