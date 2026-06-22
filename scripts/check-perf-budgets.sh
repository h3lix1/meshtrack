#!/usr/bin/env bash
# Performance budget gate (ingestion throughput, p95 query latency). Defined and
# enforced from Phase 1 once there is a pipeline to measure. Skips until then.
set -euo pipefail
cd "$(dirname "$0")/.."

# The decode-throughput budget is enforced by DecodePerfTests during `make test`.
# MapKit itself still needs xctrace for frame-time proof, but the deterministic map
# fixture and projection-cache invariants are cheap enough to gate here too.
swift test --filter MapPerformanceBudgetTests
echo "ℹ️  live map p95/hitch proof: run xctrace against --map-perf-fixture burst"
