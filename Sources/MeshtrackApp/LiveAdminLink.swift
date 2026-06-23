// LiveAdminLink — the production over-the-air admin primitive (Finding 8, SPEC §2.7/§10).
//
// ┌──────────────────────────────────────────────────────────────────────────────┐
// │  THE SINGLE DOCUMENTED HARDWARE-IN-THE-LOOP (HIL) SEAM.                         │
// └──────────────────────────────────────────────────────────────────────────────┘
//
// The whole OTA admin stack above this is now wired and exercised in production:
//
//   FleetConfigViewModel / ProvisioningWorkflow
//     → OTAAdminChannelFactory          (composition: builds the channels)
//       → MeshAdminChannel              (apply orchestration + verification)
//         → LiveAdminTransport          (the admin PROTOCOL: begin → set… → commit,
//                                          per-config-type get/set read-back)
//           → AdminLink.exchange(_:with:)  ← THIS primitive: put one admin message
//                                            on the radio, await the matching reply.
//
// Everything except this last hop is pure, testable message-shuffling (spy-tested in
// `Provisioning`). The ONLY thing that genuinely needs hardware is "write these bytes
// to the live connection and read the node's reply admin packet back".
//
// Today there is no outbound path to fulfil that: `Transport/MeshTransport` is
// INBOUND-ONLY (a frame stream — `frames()`), with no send. A correct production
// `AdminLink` must, given an `AdminMessage` + `AdminTarget`:
//   1. wrap it in a `MeshPacket` to `PortNum.adminApp`, addressed to
//      `target.nodeNum`, with the right authority (local radio / PKI admin pubkey /
//      legacy admin channel — see `AdminAuthority`);
//   2. write that packet to the live connection (USB-serial / BLE / MQTT-admin);
//   3. await + decode the node's reply admin packet and return it.
//
// Steps 1–3 need an outbound radio link that does not exist yet, so this adapter
// throws `AdminTransportError.notConnected` with a clear message. The composition is
// otherwise complete: replacing this type's body with a real outbound link is the one
// remaining hardware bring-up step — no App view-model or protocol changes needed.

import MeshProtos
import Provisioning

/// The production `AdminLink`. Wired into `OTAAdminChannelFactory` so the Fleet +
/// Provision apply paths flow through the real `MeshAdminChannel` → `LiveAdminTransport`
/// protocol. `exchange` is the one HIL effect: it throws `notConnected` until an
/// outbound radio link is added (see the file header), since `MeshTransport` is
/// inbound-only today.
struct LiveAdminLink: AdminLink {
    func exchange(_: AdminMessage, with _: AdminTarget) async throws -> AdminMessage? {
        // No outbound radio path exists yet (MeshTransport is inbound-only). Fail
        // loudly and specifically rather than echoing a same-DB success — the OTA
        // protocol + verification above are real; only the physical link is missing.
        throw AdminTransportError.notConnected
    }
}
