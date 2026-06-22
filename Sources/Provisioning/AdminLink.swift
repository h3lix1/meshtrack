// AdminLink — the lowest-level over-the-air admin seam (SPEC §2.7, §10).
//
// `AdminTransport` is the port the apply/verify flow speaks (batch-send +
// structured read-back). `LiveAdminTransport` implements all of the admin PROTOCOL
// on top of one primitive exchange: send a single `AdminMessage` to a node and
// receive its (optional) reply `AdminMessage`. THAT primitive is `AdminLink`.
//
// Why split it out: the Meshtastic admin protocol (begin/commit edit transactions,
// per-config-type get/set, owner get/set, per-channel get/set) is pure, testable
// message-shuffling — it belongs in `Provisioning` and is exercised over a SPY
// here. The ONLY thing that genuinely needs the radio is "put these bytes on the
// live connection and wait for the matching admin reply" — that is the HIL seam.
//
// The lead wires a production `AdminLink` to the live link (USB/BLE/MQTT admin):
// it must encode the `AdminMessage` into a `MeshPacket` addressed to the target
// (with the right admin authority — local, PKI admin key, or legacy admin
// channel), put it on the wire, and decode the node's reply admin packet back.
// `MeshTransport` today is INBOUND-ONLY (a frame stream), so there is no outbound
// path to reuse — see the lead-wiring note in `OTAAdminChannelFactory`.

import Foundation
import MeshProtos

/// Port: the single radio primitive the admin protocol is built on — send one
/// admin message to a node, await its (optional) reply. Set messages typically
/// return no reply (`nil`); get-request messages return the matching response.
///
/// THIS is the HIL effect boundary. Adapters: a production link over the live
/// connection (lead-wired), and a `SpyAdminLink` for tests.
public protocol AdminLink: Sendable {
    /// Send one admin message to `target` and return the node's reply, if any.
    /// Throws `AdminTransportError` on a transport fault (timeout, unauthorized,
    /// not-connected). A set/commit message returns `nil`; a get-request returns
    /// the response admin message.
    func exchange(_ message: AdminMessage, with target: AdminTarget) async throws -> AdminMessage?
}

/// Production `AdminTransport` over an `AdminLink`: implements the admin protocol
/// (ordered batch send + structured read-back) on top of the single-message
/// exchange primitive. Pure protocol logic — fully testable over a `SpyAdminLink`;
/// the radio I/O lives entirely behind the injected `AdminLink`.
public struct LiveAdminTransport: AdminTransport {
    private let link: any AdminLink

    public init(link: any AdminLink) {
        self.link = link
    }

    /// Send each admin message in order over the link (the begin → set… → commit
    /// transaction). Set/commit messages return no reply; we ignore any that come
    /// back. A transport fault on any message aborts the batch (propagated).
    public func send(_ messages: [AdminMessage], to target: AdminTarget) async throws {
        for message in messages {
            _ = try await link.exchange(message, with: target)
        }
    }

    /// Read a node's config back by issuing a get-request per requested config-type
    /// (and the owner / primary channel if asked) and collecting the responses.
    /// Drives verification — the responses flatten to the diff snapshot.
    public func readback(
        configTypes: Set<AdminMessage.ConfigType>,
        owner: Bool,
        channel: Bool,
        from target: AdminTarget
    ) async throws -> AdminReadback {
        var configs: [Config] = []
        // Deterministic order so a spy/test sees a stable request sequence.
        for type in configTypes.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let config = try await getConfig(type, from: target) {
                configs.append(config)
            }
        }
        let user = owner ? try await getOwner(from: target) : nil
        let primary = channel ? try await getPrimaryChannel(from: target) : nil
        return AdminReadback(configs: configs, owner: user, channel: primary)
    }

    // MARK: Read-request helpers

    private func getConfig(
        _ type: AdminMessage.ConfigType,
        from target: AdminTarget
    ) async throws -> Config? {
        var request = AdminMessage()
        request.getConfigRequest = type
        let reply = try await link.exchange(request, with: target)
        guard case let .getConfigResponse(config)? = reply?.payloadVariant else { return nil }
        return config
    }

    private func getOwner(from target: AdminTarget) async throws -> User? {
        var request = AdminMessage()
        request.getOwnerRequest = true
        let reply = try await link.exchange(request, with: target)
        guard case let .getOwnerResponse(user)? = reply?.payloadVariant else { return nil }
        return user
    }

    /// The primary channel carries position precision. Firmware indexes channels in
    /// `getChannelRequest` as `index + 1` (1-based); the primary is index 0 → 1.
    private func getPrimaryChannel(from target: AdminTarget) async throws -> Channel? {
        var request = AdminMessage()
        request.getChannelRequest = UInt32(Self.primaryChannelIndex + 1)
        let reply = try await link.exchange(request, with: target)
        guard case let .getChannelResponse(channel)? = reply?.payloadVariant else { return nil }
        return channel
    }

    private static let primaryChannelIndex: Int32 = 0
}
