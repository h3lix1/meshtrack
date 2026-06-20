#!/usr/bin/env bash
# Reproducible protobuf codegen gate. Regenerates MeshProtos from the vendored,
# pinned meshtastic/protobufs and fails if the working tree changes (codegen
# must be deterministic). Skips until Phase 0 wiring (scripts/gen-protos.sh) lands.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -x scripts/gen-protos.sh ]]; then
    echo "ℹ️  protobuf codegen not wired yet (scripts/gen-protos.sh); skipping"
    exit 0
fi

./scripts/gen-protos.sh

if ! git diff --quiet -- Sources/MeshProtos; then
    echo "❌ protobuf codegen is not reproducible (git diff non-empty after regen):"
    git --no-pager diff --stat -- Sources/MeshProtos
    exit 1
fi
echo "✓ protobuf codegen reproducible"
