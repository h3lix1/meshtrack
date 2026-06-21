#!/usr/bin/env bash
# Coverage floor gate. Measures line coverage over the testable library targets
# (excludes the executable composition root and the SwiftUI App layer). Floor is
# read from scoreboard.json and only ratchets up. Requires `swift test
# --enable-code-coverage` to have run first (the `test` target does this).
set -euo pipefail
cd "$(dirname "$0")/.."

FLOOR="$(python3 -c 'import json;print(json.load(open("scoreboard.json"))["gates"]["coverage_min_pct"])' 2>/dev/null || echo 70)"

BIN="$(swift build --show-bin-path 2>/dev/null || true)"
PROFDATA="$(ls "$BIN"/codecov/*.profdata 2>/dev/null | head -1 || true)"
XCTEST="$(ls -d "$BIN"/*.xctest 2>/dev/null | head -1 || true)"

if [[ -z "${PROFDATA:-}" || -z "${XCTEST:-}" ]]; then
    echo "⚠️  coverage artifacts not found — run 'swift test --enable-code-coverage'; skipping gate"
    exit 0
fi

EXE="$XCTEST/Contents/MacOS/$(basename "$XCTEST" .xctest)"
CORE=(Sources/Domain Sources/Persistence Sources/Transport Sources/RuleEngine Sources/Provisioning Sources/Scenario Sources/Ingest Sources/Crypto Sources/Logging)

PCT="$(xcrun llvm-cov export -summary-only -instr-profile "$PROFDATA" "$EXE" "${CORE[@]}" 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(round(d["data"][0]["totals"]["lines"]["percent"],2))')"

printf "line coverage (core modules): %s%%   floor: %s%%\n" "$PCT" "$FLOOR"
awk -v p="$PCT" -v f="$FLOOR" 'BEGIN{ exit !(p+0 >= f+0) }' \
    || { echo "❌ coverage ${PCT}% is below floor ${FLOOR}%"; exit 1; }
echo "✓ coverage gate passed"
