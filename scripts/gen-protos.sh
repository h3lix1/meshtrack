#!/usr/bin/env bash
# Reproducible SwiftProtobuf codegen for the MeshProtos target.
#
# Regenerates Sources/MeshProtos/*.pb.swift from the vendored, pinned
# meshtastic/protobufs sources (vendor/protobufs/, see vendor/protobufs/COMMIT).
# Deterministic + idempotent: re-running with the same toolchain + vendored
# inputs leaves the working tree unchanged. scripts/check-protobuf-codegen.sh
# enforces that (git diff -- Sources/MeshProtos must be empty after regen).
#
# Requires: protoc + protoc-gen-swift. The pinned SwiftProtobuf runtime
# (Package.resolved) is 1.38.0; install the matching plugin with
#   brew install swift-protobuf
# so generated code and the linked runtime agree.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

VENDOR_DIR="vendor/protobufs"
PROTO_ROOT="$REPO_ROOT/$VENDOR_DIR"
OUT_DIR="$REPO_ROOT/Sources/MeshProtos"
PIN_FILE="$PROTO_ROOT/COMMIT"

# --- Prefer the Homebrew toolchain ----------------------------------------
# Homebrew's swift-protobuf bottle ships protoc-gen-swift alongside a protoc
# that bundles the google/protobuf well-known types. Putting it first on PATH
# keeps the plugin version aligned with the pinned runtime.
if command -v brew >/dev/null 2>&1; then
    PATH="$(brew --prefix)/bin:$PATH"
fi
export PATH

require() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "❌ $1 not found on PATH. $2" >&2
        exit 1
    }
}
require protoc "Install with: brew install protobuf"
require protoc-gen-swift "Install with: brew install swift-protobuf"

[[ -f "$PIN_FILE" ]] || { echo "❌ missing $VENDOR_DIR/COMMIT (pinned upstream SHA)" >&2; exit 1; }
PINNED_COMMIT="$(tr -d '[:space:]' < "$PIN_FILE")"

# Well-known types (google/protobuf/descriptor.proto) bundled with protoc.
# Resolve the include dir from the protoc install prefix so this is not
# hard-coded to one machine layout.
WKT_INCLUDE=""
for cand in \
    "$(brew --prefix protobuf 2>/dev/null)/include" \
    "$(brew --prefix 2>/dev/null)/include" \
    "/usr/local/include" \
    "/opt/homebrew/include"; do
    if [[ -n "$cand" && -f "$cand/google/protobuf/descriptor.proto" ]]; then
        WKT_INCLUDE="$cand"
        break
    fi
done
[[ -n "$WKT_INCLUDE" ]] || {
    echo "❌ could not locate google/protobuf/descriptor.proto (protoc well-known types)." >&2
    echo "   Tried the protoc install prefix; install protobuf via brew." >&2
    exit 1
}

echo "==> protoc:            $(protoc --version)  ($(command -v protoc))"
echo "==> protoc-gen-swift:  $(protoc-gen-swift --version)  ($(command -v protoc-gen-swift))"
echo "==> vendored protos:   $VENDOR_DIR @ $PINNED_COMMIT"
echo "==> well-known types:  $WKT_INCLUDE"
echo "==> output dir:        Sources/MeshProtos"

# --- Collect inputs deterministically -------------------------------------
# Sorted, repo-relative paths so the protoc invocation (and any path-derived
# ordering in the output) is stable across machines and filesystems.
# Portable to bash 3.2 (macOS default) — no mapfile/readarray.
PROTOS=()
while IFS= read -r p; do
    PROTOS+=("$p")
done < <(cd "$PROTO_ROOT" && find . -name '*.proto' | sed 's#^\./##' | LC_ALL=C sort)
[[ ${#PROTOS[@]} -gt 0 ]] || { echo "❌ no .proto files under $VENDOR_DIR" >&2; exit 1; }
echo "==> generating ${#PROTOS[@]} proto file(s)"

# --- Clean stale generated output (only *.pb.swift; never hand-written src) -
find "$OUT_DIR" -name '*.pb.swift' -delete

# --- Generate --------------------------------------------------------------
# -I PROTO_ROOT  resolves both `import "meshtastic/..."` and `import "nanopb.proto"`.
# -I WKT_INCLUDE resolves `import "google/protobuf/descriptor.proto"`.
# FileNaming=DropPath flattens meshtastic/foo.proto -> foo.pb.swift in OUT_DIR.
( cd "$PROTO_ROOT" && protoc \
    -I "$PROTO_ROOT" \
    -I "$WKT_INCLUDE" \
    --swift_opt=Visibility=Public \
    --swift_opt=FileNaming=DropPath \
    --swift_out="$OUT_DIR" \
    "${PROTOS[@]}" )

GEN_COUNT="$(find "$OUT_DIR" -name '*.pb.swift' | wc -l | tr -d '[:space:]')"
echo "✓ generated $GEN_COUNT *.pb.swift file(s) in Sources/MeshProtos"
