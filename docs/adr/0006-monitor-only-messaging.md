# ADR 0006 — Monitor-only messaging

- Status: accepted
- Date: 2026-06-20

## Context
SPEC §1 listed "chat/messaging UX" as a non-goal: we monitor, we don't replace the
official client. Phase 7 needs to show channel/DM text so operators can see what the
fleet is saying — the most-requested missing view. The risk of becoming a full chat
client (a send/TX path, message reliability, ACKs, threading) is real and is exactly
what we said we wouldn't build.

## Decision
Add **monitor-only** messaging and amend SPEC §1 accordingly:
- Decode `TEXT_MESSAGE_APP` (port 1) payloads in the ingest pipeline into a new
  `message(packet_id, from_num, to_num, channel, channel_name, body, rx_time, is_dm)`
  table (migration v3).
- A read-only **Channels** view groups messages by channel with sender short-name,
  @mention highlighting, timestamps, and a broadcast/DM distinction.
- Encrypted channels decode only with the PSK already held in `KeyStore`; no new key
  surface.
- **No send path.** Composing/sending messages is explicitly out of scope for
  Phase 7. The non-goal narrows from "messaging" to "*two-way* chat".

## Consequences
- Stays true to "we monitor"; the TX/admin surface does not grow.
- `message` is append-only and subject to the same dedup window as other extractions
  (count once per `(packet_id, from_num)`).
- A future ADR may add a guarded send path; until then the view is read-only and
  tested over decoded sample corpora.
