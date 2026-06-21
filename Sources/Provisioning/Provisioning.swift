// Provisioning — templates, the naming DSL renderer (with hard byte-limit
// validation), config diff, and AdminMessage/ConfigModule apply (SPEC §2.7).
//
//   • NamingDSL.swift — render `{shortName}-{id[-4:]}` style templates and
//     enforce the Meshtastic byte limits (short ≤ 4 bytes, long ≤ 39 bytes).
//   • (Phase 4) Template model, render→diff→confirm→apply, read-back verify.
