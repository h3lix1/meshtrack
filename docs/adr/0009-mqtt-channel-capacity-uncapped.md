# ADR 0009 — MQTT channel capacity is uncapped (local stays at 7)

- Status: accepted
- Date: 2026-06-22
- Supersedes: the "up to 20 channels for MQTT" clause of SPEC §10.2 (decision 2)

## Context
SPEC §10.2 originally resolved channel capacity as "up to **20** channels for MQTT,
**7** for the local device." The 7-channel local limit is a hard **firmware**
constraint: a physical Meshtastic node has 8 channel slots (one reserved), so the
device can run at most 7 user channels. The "20" figure for MQTT was carried over by
analogy, but MQTT channels are not a device resource — they are topic/PSK
subscriptions Meshtrack tracks in software. A fleet operator monitoring the public
mesh routinely wants to observe more than 20 distinct MQTT channels, and there is no
hardware or protocol reason to cap them. Phase 8 implemented MQTT as uncapped to match
this reality; this left code (and tests) diverging from the written SPEC, surfaced as
phase-8 review finding #14.

## Decision
- **MQTT channels are uncapped.** Meshtrack imposes no fixed upper bound on the number
  of MQTT channels/PSKs an operator may configure; capacity is bounded only by
  practical resource use, not a product rule.
- **Local device channels remain capped at 7**, reflecting the firmware slot limit.
- The Channels & Keys UI presents MQTT capacity as effectively unlimited and continues
  to enforce the 7-channel local cap.

We record this as a deliberate decision rather than "drift": the code is correct and
the docs are updated to match. SPEC §10.2 and AGENTS.md are amended accordingly.

## Consequences
- `ChannelsSettingsViewModel` keeps no MQTT cap and rejects an 8th local channel; the
  test asserting the 21st MQTT channel is allowed is intentional, not a bug.
- Keychain/`app_config` channel storage must scale gracefully with many MQTT channels
  (no fixed-size assumptions).
- If a future product reason to cap MQTT emerges, supersede this ADR rather than
  silently re-introducing a limit.
