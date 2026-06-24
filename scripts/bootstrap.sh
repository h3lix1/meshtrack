#!/usr/bin/env bash
# Install developer tooling the gate suite uses. Idempotent.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Installing dev tooling"

if command -v brew >/dev/null 2>&1; then
    brew install swiftformat swiftlint protobuf swift-protobuf || true
else
    echo "⚠️  Homebrew not found; install swiftformat, swiftlint, protobuf, and swift-protobuf manually."
fi

# protoc + protoc-gen-swift drive reproducible protobuf codegen (Phase 0).
if ! command -v protoc >/dev/null 2>&1; then
    echo "ℹ️  protoc not found; needed for MeshProtos codegen. brew install protobuf"
fi
if ! command -v protoc-gen-swift >/dev/null 2>&1; then
    echo "ℹ️  protoc-gen-swift not found; needed for MeshProtos codegen. brew install swift-protobuf"
fi

echo "==> Bootstrap complete."
