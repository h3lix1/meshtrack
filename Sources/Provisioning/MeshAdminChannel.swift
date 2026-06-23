// MeshAdminChannel — the real `AdminChannel` over the air (SPEC §2.7).
//
// This is the production sibling of `StoreBackedAdminChannel`: instead of reading
// and writing Meshtrack's local record, it constructs `AdminMessage` protobufs
// (via the pure `AdminMessageMapping`) and carries them to a physical radio over
// an `AdminTransport` — local USB/BLE or remote PKI/legacy admin. The same
// `AdminApplier` render→diff→apply→read-back→verify flow runs on top, unchanged.
//
// Layering:
//   AdminApplier (orchestration, pure)
//     └─ MeshAdminChannel  (this — AdminChannel port; pure mapping + the effect)
//          └─ AdminTransport (the HIL effect boundary; radio I/O)
//          └─ AdminMessageMapping (pure: change↔AdminMessage / Config↔snapshot)
//
// NEVER auto-applies: `apply` only sends what it is handed, which the workflow
// builds solely from an operator-confirmed `ApplyPlan`. `validate` runs first so a
// malformed template (unknown region/role) is rejected before any message is sent.

import Foundation
import MeshProtos

/// A live `AdminChannel` that provisions a physical node via admin messages.
public struct MeshAdminChannel: AdminChannel {
    private let transport: any AdminTransport
    private let target: AdminTarget
    /// The config-types `currentConfig()` reads when nothing narrower is known.
    /// Region is always read (legal — it must be confirmed present, SPEC §2.9).
    /// Position precision is NOT a config-type — it is read from the primary
    /// channel (see `currentConfig`'s `channel: true`).
    private let baselineConfigTypes: Set<AdminMessage.ConfigType>
    /// The module-config-types `currentConfig()` reads. Module fields (MQTT,
    /// telemetry, …) live in `ModuleConfig`, read via `getModuleConfigRequest`. The
    /// baseline is empty (modules are opt-in); a richer caller can widen it so a
    /// template that provisions module fields read-back verifies.
    private let baselineModuleConfigTypes: Set<AdminMessage.ModuleConfigType>

    public init(
        transport: any AdminTransport,
        target: AdminTarget,
        baselineConfigTypes: Set<AdminMessage.ConfigType> = [.loraConfig, .deviceConfig],
        baselineModuleConfigTypes: Set<AdminMessage.ModuleConfigType> = []
    ) {
        self.transport = transport
        self.target = target
        self.baselineConfigTypes = baselineConfigTypes
        self.baselineModuleConfigTypes = baselineModuleConfigTypes
    }

    /// Read the node's current provisionable config into the string snapshot the
    /// diff compares against. Requests the baseline config + module-config types,
    /// the owner, and the primary channel (which carries position precision).
    public func currentConfig() async throws -> [String: String] {
        let readback = try await transport.readback(
            configTypes: baselineConfigTypes,
            moduleConfigTypes: baselineModuleConfigTypes,
            owner: true,
            channel: true,
            from: target
        )
        return Self.snapshot(from: readback)
    }

    /// Send a single imperative node command (favorite / unfavorite / ignore /
    /// unignore) over the transport. Unlike a config apply these are not wrapped in a
    /// begin/commit transaction and have no read-back verification — the firmware
    /// applies them immediately and they are idempotent. Throws on a transport fault.
    public func send(_ command: NodeAdminCommand) async throws {
        try await transport.send([AdminMessageMapping.message(for: command)], to: target)
    }

    /// Apply confirmed changes: build the begin→set…→commit admin messages and
    /// send them over the transport. (Validation runs upstream in `AdminApplier`,
    /// shared across every adapter; read-back verification is also the
    /// `AdminApplier`'s job, which re-reads via `currentConfig()`.)
    ///
    /// Position precision is per-channel and `setChannel` REPLACES the whole channel,
    /// so when a change touches precision we first read back the node's current
    /// primary channel and feed it to the mapping as a read-modify-write — the
    /// emitted `setChannel` preserves the existing name, PSK, role and uplink/
    /// downlink flags and only moves `positionPrecision`.
    public func apply(_ changes: [ConfigChange]) async throws {
        guard !changes.isEmpty else { return }
        let (channel, modules) = try await currentSlotsIfNeeded(for: changes)
        let messages = try AdminMessageMapping.messages(
            for: changes,
            currentPrimaryChannel: channel,
            currentModuleConfigs: modules
        )
        guard !messages.isEmpty else { return }
        try await transport.send(messages, to: target)
    }

    /// Read back the node's current primary `Channel` and/or touched `ModuleConfig`s
    /// — but ONLY when a change touches one — so the apply is a read-modify-write
    /// that preserves the fields it doesn't mutate (`setChannel` / `setModuleConfig`
    /// both REPLACE the whole sub-message). Returns `(nil, [])` when neither is
    /// touched (no extra read needed).
    private func currentSlotsIfNeeded(
        for changes: [ConfigChange]
    ) async throws -> (channel: Channel?, modules: [ModuleConfig]) {
        let wantsChannel = AdminMessageMapping.touchesChannel(changes)
        let moduleTypes = (try? AdminMessageMapping.moduleConfigTypes(for: changes)) ?? []
        guard wantsChannel || !moduleTypes.isEmpty else { return (nil, []) }
        let readback = try await transport.readback(
            configTypes: [],
            moduleConfigTypes: moduleTypes,
            owner: false,
            channel: wantsChannel,
            from: target
        )
        return (readback.channel, readback.modules)
    }

    /// Flatten a multi-config read-back into the diff snapshot, merging each
    /// config-type's and module-config-type's contribution plus the owner and the
    /// primary channel.
    static func snapshot(from readback: AdminReadback) -> [String: String] {
        var snapshot: [String: String] = [:]
        for config in readback.configs {
            for (key, value) in AdminMessageMapping.snapshot(config: config) {
                snapshot[key] = value
            }
        }
        for module in readback.modules {
            for (key, value) in AdminMessageMapping.snapshot(module: module) {
                snapshot[key] = value
            }
        }
        for (key, value) in AdminMessageMapping.snapshot(
            owner: readback.owner, channel: readback.channel
        ) {
            snapshot[key] = value
        }
        return snapshot
    }
}
