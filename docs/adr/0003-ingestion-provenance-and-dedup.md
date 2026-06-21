# ADR 0003 — Ingestion: append-only provenance + pipeline dedup

- Status: accepted
- Date: 2026-06-20

## Context
The same `MeshPacket` arrives via the local node, MQTT, and many gateways. We
must keep full reception provenance (which gateway, RSSI/SNR, hop counts) yet
count telemetry/position exactly once (SPEC §2.4).

## Decision
- `observation` is **append-only provenance**: one row per reception. The unique
  index is `(packet_id, node_num, gateway_id, transport)` — multi-gateway copies
  are distinct rows; only an exact re-delivery is rejected (idempotent on
  backfill/reconnect). The earlier `UNIQUE(packet_id, node_num)` was too strict.
- Once-only counting of telemetry/position is the pipeline's job via a pure
  `DedupWindow` (sliding window keyed by `(packet_id, from_num)`, default 10 min),
  not a DB constraint.
- Decoding is total: `PacketDecoder` turns ServiceEnvelope bytes into a pure
  `DecodedPacket`, decrypting `/e/` payloads via the `PacketDecryptor` + `KeyStore`
  ports. Malformed input throws; unkeyed encrypted packets are skipped.

## Consequences
- Validated on live bayme.sh MediumFast traffic: 62 of 69 frames were multi-gateway
  duplicates collapsed by `DedupWindow`, with real telemetry/positions extracted
  once — the §2.4 scenario proven on real data.
- The pipeline is deterministic and unit-testable with constructed frames.
