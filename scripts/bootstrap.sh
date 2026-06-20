#!/usr/bin/env bash
# Install developer tooling the gate suite uses. Idempotent.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> Installing dev tooling"

if command -v brew >/dev/null 2>&1; then
    brew install swiftformat swiftlint || true
else
    echo "⚠️  Homebrew not found; install swiftformat + swiftlint manually."
fi

# Muter (mutation testing) is not in brew-core; install via Mint when available.
if ! command -v muter >/dev/null 2>&1; then
    if command -v mint >/dev/null 2>&1; then
        mint install muter-mutation-testing/muter \
            || echo "⚠️  muter install via mint failed; mutation gate will skip locally."
    else
        echo "ℹ️  muter not installed (no mint). Mutation gate skips locally; CI installs it."
        echo "    To enable locally: brew install mint && mint install muter-mutation-testing/muter"
    fi
fi

# protoc + protoc-gen-swift drive reproducible protobuf codegen (Phase 0).
if ! command -v protoc >/dev/null 2>&1; then
    echo "ℹ️  protoc not found; needed for MeshProtos codegen. brew install protobuf"
fi
if ! command -v protoc-gen-swift >/dev/null 2>&1; then
    echo "ℹ️  protoc-gen-swift not found; needed for MeshProtos codegen. brew install swift-protobuf"
fi

echo "==> Bootstrap complete."
