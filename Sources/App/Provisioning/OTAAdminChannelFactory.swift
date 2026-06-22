// OTAAdminChannelFactory — the production over-the-air admin wiring (SPEC §2.7, §10).
//
// This is the real remote-admin apply path, the production replacement for
// `StoreBackedAdminChannel` (which only round-trips Meshtrack's DB and "verifies"
// against the same DB — no admin message is ever sent, so SPEC §10 remote-admin is
// unexercised). Every channel this factory builds is a `MeshAdminChannel` over a
// `LiveAdminTransport`, so an apply SENDS real begin → set… → commit admin messages
// over the live link and verifies by READING the node's config back — not a same-DB
// echo.
//
// It produces the two resolver closures the live view models expect:
//   • `fleetChannelFor(_:)`     → `@Sendable (Int64) -> any AdminChannel`
//                                  (FleetConfigViewModel / FleetRolloutViewModel)
//   • `provisionChannelFor(_:)` → `@Sendable (AdminTarget) -> any AdminChannel`
//                                  (ProvisioningWorkflowFactory.make(channelFor:))
//
// Both flow through one injected `AdminLink` — the single radio primitive (send an
// admin message, await the reply). The admin PROTOCOL (transactions, get/set,
// read-back) is `LiveAdminTransport`, pure and tested over a spy; only the
// `AdminLink` touches the radio.
//
// LEAD WIRING (the one remaining HIL step): `MeshTransport` is INBOUND-ONLY (a
// frame stream), so there is no outbound admin path to reuse yet. The lead must
// supply a production `AdminLink` that, given an `AdminMessage` + `AdminTarget`:
//   1. wraps it in a `MeshPacket` to `PortNum.adminApp`, addressed to
//      `target.nodeNum`, using the right authority (local radio, PKI admin pubkey,
//      or legacy admin channel — see `AdminAuthority`);
//   2. writes it to the live connection (USB/BLE/MQTT);
//   3. awaits and decodes the node's reply admin packet, returning it.
// Then in `AppComposition.swift`, replace the two `channelFor: nil` call sites with
// this factory's closures (see the per-section notes below). No App view model
// changes are needed — both already take a `channelFor` override.

import Domain
import Provisioning

/// Builds production OTA `AdminChannel`s (`MeshAdminChannel` over `LiveAdminTransport`)
/// for the Fleet and Provision flows, all over a single injected `AdminLink`.
public struct OTAAdminChannelFactory: Sendable {
    private let link: any AdminLink
    /// The authority Fleet rollouts use (Fleet has no per-node authority picker, so a
    /// fleet-wide default is applied; the Provision flow carries its own `AdminTarget`
    /// authority). Defaults to `.local` (the directly-attached radio).
    private let fleetAuthority: AdminAuthority

    public init(link: any AdminLink, fleetAuthority: AdminAuthority = .local) {
        self.link = link
        self.fleetAuthority = fleetAuthority
    }

    /// A channel for a node number (Fleet). Authority is the fleet-wide default.
    public func channel(forNodeNum nodeNum: Int64) -> any AdminChannel {
        channel(for: AdminTarget(nodeNum: nodeNum, authority: fleetAuthority))
    }

    /// A channel for an already-resolved `AdminTarget` (Provision carries authority).
    public func channel(for target: AdminTarget) -> any AdminChannel {
        MeshAdminChannel(transport: LiveAdminTransport(link: link), target: target)
    }

    /// The resolver `FleetConfigViewModel` / `FleetRolloutViewModel` expect.
    /// Lead: pass this to `FleetConfigViewModel(store:channelFor:)` in `.fleet`.
    public func fleetChannelFor() -> @Sendable (Int64) -> any AdminChannel {
        { nodeNum in channel(forNodeNum: nodeNum) }
    }

    /// The resolver `ProvisioningWorkflowFactory.make` expects.
    /// Lead: pass this as `channelFor:` to `ProvisioningWorkflowFactory.make` in
    /// `.provision` (instead of `nil`).
    public func provisionChannelFor() -> @Sendable (AdminTarget) -> any AdminChannel {
        { target in channel(for: target) }
    }
}
