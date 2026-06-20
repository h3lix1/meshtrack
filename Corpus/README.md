# Golden corpus format

Real `ServiceEnvelope` frames captured from the public broker, replayed through the
*real* pipeline by `ReplayAdapter` for integration tests (SPEC §6, tier 4).

## Layout
```
Corpus/
  <name>/
    meta.json          # capture metadata
    frames.ndjson      # one frame per line, in capture order
```

## meta.json
```json
{
  "name": "baymesh-lite-2026-06",
  "source": "mqtt.meshtastic.org",
  "captured_at": "2026-06-18T12:00:00Z",
  "topic_filter": "msh/US/2/e/#",
  "frame_count": 1234,
  "notes": "public broker, LongFast; PSKs NOT included (decryption tested separately)"
}
```

## frames.ndjson (one JSON object per line)
```json
{"seq":0,"rx_time_ns":1718712000000000000,"transport":"mqtt","topic":"msh/US/2/e/LongFast/!a1b2c3d4","gateway_id":"!a1b2c3d4","payload_b64":"<base64 of raw ServiceEnvelope bytes>"}
```

Fields map 1:1 to `Transport.InboundFrame`: `payload_b64` decodes to the raw
on-the-wire bytes; `rx_time_ns` drives the replay clock (`InjectedClock`). Frames
are emitted in `seq` order with `receivedAt = Instant(nanosecondsSinceEpoch: rx_time_ns)`.

## Rules
- **No secrets.** Never commit PSKs, admin keys, or credentials. Decryption is
  tested with fixtures and Keychain, not corpus PSKs.
- Captures are append-only and timestamped; treat them as fixtures, not logs.
- Keep each capture small and focused (one behavior per scenario where possible).
