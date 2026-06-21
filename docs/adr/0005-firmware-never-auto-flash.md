# ADR 0005 — Firmware onboarding: never auto-flash, verify before write

- Status: accepted
- Date: 2026-06-20

## Context
Flashing the wrong binary or to the wrong chip family bricks a board. The flash
method itself branches by chip family — esptool does NOT apply to nRF52/RP2040
(SPEC §2.8). This feature is extra-credit, behind a feature flag and a HIL gate.

## Decision
- `ChipDetection` maps a hardware model to a `ChipFamily`; `flashMethod` branches
  (ESP32* → esptool at chip-specific offsets; nRF52/RP2040 → UF2).
- `FirmwareVerifier` enforces variant↔hardware compatibility and a **pinned
  SHA-256** before any write.
- `GuardedFlasher` **never auto-flashes**: it writes only when the feature flag is
  on, the image matches the detected chip, the checksum verifies, the flasher's
  method matches the chip, and an explicit per-board `FlashConfirmation` is given.
- Real esptool/UF2 process I/O is an effect adapter, validated on hardware (HIL),
  never in CI.

## Consequences
- Read-only HIL check on the test XIAO confirmed ESP32-S3 → `.esp32s3` → esptool at
  offset `0x0000`, matching the detection unit tests. Flashing stays manual and
  confirmed.
