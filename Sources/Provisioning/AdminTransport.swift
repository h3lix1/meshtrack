// AdminTransport — the effect boundary for over-the-air admin (SPEC §2.7).
//
// `AdminMessageMapping` builds the `AdminMessage` protobufs purely; this port is
// the *only* place those messages touch a radio. Adapters implement it over a
// real `MeshTransport` (local USB/BLE) or a remote admin path (PKI admin key or
// legacy admin channel). The actual radio I/O is validated on hardware (HIL), not
// in CI; tests drive `MeshAdminChannel` over a fake `AdminTransport`.
//
// The port speaks already-built `AdminMessage`s and returns the node's read-back
// `Config`/`User` so verification compares like-for-like. It carries the routing
// (which node, over which admin authority) so a single channel can target a local
// or a remote node without the apply logic knowing the difference.

import Foundation
import MeshProtos

/// How an admin message is authorised to reach a node (SPEC §2.7: remote admin
/// requires an installed admin key — a PKI admin pubkey or the legacy admin
/// channel). Local admin is the directly-attached radio.
public enum AdminAuthority: Sendable, Equatable {
    /// The directly-attached radio over USB or BLE — no admin key needed.
    case local
    /// A remote node reached with an installed PKI admin pubkey. The key itself
    /// lives in the local app store; this carries only its identifier, never key bytes.
    case remotePKI(adminKeyID: String)
    /// A remote node reached over the legacy shared admin channel.
    case remoteLegacyChannel(channelName: String)

    /// Whether this authority targets a node over the air (vs. directly attached).
    public var isRemote: Bool {
        switch self {
        case .local: false
        case .remotePKI, .remoteLegacyChannel: true
        }
    }
}

/// Identifies the node an admin session targets and how it is authorised.
public struct AdminTarget: Sendable, Equatable {
    /// The destination node number (the radio being provisioned).
    public let nodeNum: Int64
    public let authority: AdminAuthority

    public init(nodeNum: Int64, authority: AdminAuthority) {
        self.nodeNum = nodeNum
        self.authority = authority
    }
}

/// A node's read-back: the `Config` for each requested config-type, the
/// `ModuleConfig` for each requested module-type, the owner `User`, and the
/// primary `Channel` (which carries position precision).
/// `AdminMessageMapping.snapshot` flattens these to the diff snapshot.
public struct AdminReadback: Sendable, Equatable {
    public let configs: [Config]
    public let modules: [ModuleConfig]
    public let owner: User?
    public let channel: Channel?

    public init(
        configs: [Config] = [],
        modules: [ModuleConfig] = [],
        owner: User? = nil,
        channel: Channel? = nil
    ) {
        self.configs = configs
        self.modules = modules
        self.owner = owner
        self.channel = channel
    }
}

/// A typed failure on the admin transport (the effect boundary). Distinct from
/// `AdminMappingError` (pure construction) and `ApplyError` (verification).
public enum AdminTransportError: Error, Equatable, Sendable {
    /// No response (or an incomplete one) came back within the deadline.
    case timeout
    /// The node refused the session (e.g. missing/invalid admin key for remote).
    case unauthorized
    /// The transport is not connected to the target.
    case notConnected
    /// The node replied with an error we could not interpret.
    case nodeError(String)
}

/// Port: sends already-built admin messages to a node and reads its config back.
/// THIS is the HIL effect boundary; the message construction is pure (mapping).
public protocol AdminTransport: Sendable {
    /// Send a sequence of admin messages to `target`, in order. Used for the
    /// begin → set… → commit transaction of an apply. Throws on a transport fault;
    /// returns when the node has acknowledged the batch.
    func send(_ messages: [AdminMessage], to target: AdminTarget) async throws

    /// Read back a node's config: request each config-type and module-config-type
    /// (and the owner and/or the primary channel if asked), and return what the node
    /// reports. Drives verification. The channel carries position precision (a
    /// per-channel module setting), so a precision change asks for it via
    /// `channel: true`. Module config fields (MQTT, telemetry, …) are read via
    /// `moduleConfigTypes`.
    func readback(
        configTypes: Set<AdminMessage.ConfigType>,
        moduleConfigTypes: Set<AdminMessage.ModuleConfigType>,
        owner: Bool,
        channel: Bool,
        from target: AdminTarget
    ) async throws -> AdminReadback
}

public extension AdminTransport {
    /// Back-compat overload: read back with no module-config types (the original
    /// config-only surface). New callers pass `moduleConfigTypes` explicitly.
    func readback(
        configTypes: Set<AdminMessage.ConfigType>,
        owner: Bool,
        channel: Bool,
        from target: AdminTarget
    ) async throws -> AdminReadback {
        try await readback(
            configTypes: configTypes,
            moduleConfigTypes: [],
            owner: owner,
            channel: channel,
            from: target
        )
    }
}
