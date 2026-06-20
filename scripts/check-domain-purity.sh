#!/usr/bin/env bash
# Architectural keystone gate: the Domain module must be PURE.
# No effectful frameworks, no wall-clock reads, no force-unwraps. Always runs
# (no external tool required) so this invariant can never silently regress.
set -euo pipefail
cd "$(dirname "$0")/.."

DOMAIN="Sources/Domain"
fail=0

# Comment-stripped view of a file, so doc-comment prose that *mentions* Date()
# or try! doesn't trip the guard. Removes // line comments and /* */ blocks.
strip_comments() { perl -0777 -pe 's{//[^\n]*}{}g; s{/\*.*?\*/}{}gs' "$1"; }

# 1) Domain imports nothing but the standard library (+ Synchronization).
#    Anchored at line start, so commented-out / prose imports can't match.
BANNED_IMPORTS='^[[:space:]]*import[[:space:]]+(Foundation|GRDB|SwiftProtobuf|MeshProtos|Transport|Persistence|RuleEngine|Provisioning|CoreBluetooth|Network|CocoaMQTT|IOKit|UserNotifications|MapKit|SwiftUI|Charts|SQLite3)\b'
if grep -rnE "$BANNED_IMPORTS" "$DOMAIN"; then
    echo "❌ Domain imports a banned effectful framework — Domain must be pure (stdlib only)."
    fail=1
fi

# 2) No wall-clock reads (Date()), and 3) no force-unwrap try!/as! — checked on
#    comment-stripped code only.
while IFS= read -r -d '' file; do
    code="$(strip_comments "$file")"
    if grep -nE '\bDate[[:space:]]*\(' <<<"$code" >/dev/null; then
        echo "❌ $file: Domain calls Date(); read time through the Clock port instead."
        fail=1
    fi
    if grep -nE '\btry!|\bas!' <<<"$code" >/dev/null; then
        echo "❌ $file: Domain uses try!/as!; use typed errors."
        fail=1
    fi
done < <(find "$DOMAIN" -name '*.swift' -print0)

if [[ $fail -eq 0 ]]; then
    echo "✓ Domain purity verified"
else
    exit 1
fi
