#!/usr/bin/env bash
# Performance budget gate (ingestion throughput, p95 query latency). Defined and
# enforced from Phase 1 once there is a pipeline to measure. Skips until then.
set -euo pipefail
cd "$(dirname "$0")/.."

# The decode-throughput budget is enforced as a unit test (DecodePerfTests, run by
# `make test`); p95 query-latency budgets land with the query layer. This gate is
# the human-facing reminder — the hard enforcement is the test + scoreboard.json.
echo "ℹ️  decode-throughput budget enforced via DecodePerfTests; p95 query budget TBD"
exit 0
