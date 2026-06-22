#!/usr/bin/env bash
# Mutation-testing gate. Runs Muter against the first-party Sources/ modules and
# enforces the mutation-score floor from scoreboard.json (gates.mutation_min_score).
#
# Enforcement model (mirrors the rest of the gate suite):
#   - Locally (CI unset/empty): muter is not in brew-core and is usually absent,
#     so a missing muter/muter.conf.yml degrades to a warning + skip. This keeps
#     `make verify` green for contributors who haven't run `make bootstrap`.
#   - CI (CI non-empty): every prerequisite is HARD. A missing muter toolchain,
#     a missing muter.conf.yml, a failed run, or a measured score below the floor
#     fails the gate. CI installs muter (see .github/workflows/verify.yml), so a
#     skip in CI means the floor was never measured — which is exactly the hole
#     this gate closes.
#
# We do NOT write a mutation_score back into scoreboard.json here — that metric is
# updated only by a deliberate, real run, never fabricated by the gate.
set -euo pipefail
cd "$(dirname "$0")/.."

FLOOR="$(python3 -c 'import json;print(json.load(open("scoreboard.json"))["gates"]["mutation_min_score"])' 2>/dev/null || echo 60)"

# Treat any non-empty CI value as "in CI" (GitHub Actions sets CI=true).
in_ci() { [[ -n "${CI:-}" ]]; }

fail_or_skip() {
    # $1 = human reason
    if in_ci; then
        echo "❌ mutation gate: $1 (CI enforces; install muter + commit muter.conf.yml)"
        exit 1
    fi
    echo "⚠️  $1; skipping mutation gate (CI enforces)"
    exit 0
}

command -v muter >/dev/null 2>&1 || fail_or_skip "muter is not installed"
[[ -f muter.conf.yml ]]            || fail_or_skip "muter.conf.yml is missing"

echo "==> Running Muter (floor: ${FLOOR}%)"
RUN_LOG="$(mktemp)"
trap 'rm -f "$RUN_LOG"' EXIT

if ! muter run | tee "$RUN_LOG"; then
    fail_or_skip "muter run failed"
fi

# Parse the mutation score from Muter's report. Muter prints a final
# "Mutation Score of test run: NN%" line; grab the last percentage on that line.
SCORE="$(grep -iE 'mutation score' "$RUN_LOG" | tail -1 | grep -oE '[0-9]+(\.[0-9]+)?' | tail -1 || true)"

if [[ -z "${SCORE:-}" ]]; then
    fail_or_skip "could not parse a mutation score from muter output"
fi

printf "mutation score: %s%%   floor: %s%%\n" "$SCORE" "$FLOOR"
awk -v s="$SCORE" -v f="$FLOOR" 'BEGIN{ exit !(s+0 >= f+0) }' \
    || { echo "❌ mutation score ${SCORE}% is below floor ${FLOOR}%"; exit 1; }
echo "✓ mutation gate passed"
