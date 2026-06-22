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

    public init(
        transport: any AdminTransport,
        target: AdminTarget,
        baselineConfigTypes: Set<AdminMessage.ConfigType> = [.loraConfig, .deviceConfig]
    ) {
        self.transport = transport
        self.target = target
        self.baselineConfigTypes = baselineConfigTypes
    }

    /// Read the node's current provisionable config into the string snapshot the
    /// diff compares against. Requests the baseline config-types, the owner, and
    /// the primary channel (which carries position precision).
    public func currentConfig() async throws -> [String: String] {
        let readback = try await transport.readback(
            configTypes: baselineConfigTypes,
            owner: true,
            channel: true,
            from: target
        )
        return Self.snapshot(from: readback)
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
        let current = try await currentPrimaryChannelIfNeeded(for: changes)
        let messages = try AdminMessageMapping.messages(for: changes, currentPrimaryChannel: current)
        guard !messages.isEmpty else { return }
        try await transport.send(messages, to: target)
    }

    /// Read back the node's current primary `Channel` when (and only when) a change
    /// touches a per-channel setting (position precision) — so the precision apply is
    /// a read-modify-write that preserves the rest of the channel. Returns `nil` when
    /// no precision change is present (no channel read needed).
    private func currentPrimaryChannelIfNeeded(for changes: [ConfigChange]) async throws -> Channel? {
        guard AdminMessageMapping.touchesChannel(changes) else { return nil }
        let readback = try await transport.readback(
            configTypes: [], owner: false, channel: true, from: target
        )
        return readback.channel
    }

    /// Flatten a multi-config read-back into the diff snapshot, merging each
    /// config-type's contribution plus the owner and the primary channel.
    static func snapshot(from readback: AdminReadback) -> [String: String] {
        var snapshot: [String: String] = [:]
        for config in readback.configs {
            for (key, value) in AdminMessageMapping.snapshot(config: config, owner: nil) {
                snapshot[key] = value
            }
        }
        for (key, value) in AdminMessageMapping.snapshot(
            config: nil, owner: readback.owner, channel: readback.channel
        ) {
            snapshot[key] = value
        }
        return snapshot
    }
}
