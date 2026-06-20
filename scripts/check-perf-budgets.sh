#!/usr/bin/env bash
# Performance budget gate (ingestion throughput, p95 query latency). Defined and
# enforced from Phase 1 once there is a pipeline to measure. Skips until then.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "ℹ️  performance budgets are defined from Phase 1; skipping (see scoreboard.json)"
exit 0
