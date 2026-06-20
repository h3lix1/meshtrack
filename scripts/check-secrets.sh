#!/usr/bin/env bash
# Secret scan. Uses gitleaks when present, otherwise a built-in pattern scan.
# Secrets (PSKs, admin keys, MQTT creds) belong in Keychain, never in the repo.
set -euo pipefail
cd "$(dirname "$0")/.."

if command -v gitleaks >/dev/null 2>&1; then
    gitleaks detect --no-banner --redact -v && { echo "✓ gitleaks: no secrets"; exit 0; }
    echo "❌ gitleaks found potential secrets"; exit 1
fi

echo "ℹ️  gitleaks not installed; running built-in pattern scan"
PATTERNS='AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|xox[baprs]-[0-9A-Za-z-]{10,}|ghp_[0-9A-Za-z]{36}|AIza[0-9A-Za-z_-]{35}|[Ss][Ee][Cc][Rr][Ee][Tt]_?[Kk][Ee][Yy][[:space:]]*=[[:space:]]*["'\''][^"'\'']{12,}'

HITS="$(grep -rIEn "$PATTERNS" . \
    --exclude-dir=.git --exclude-dir=.build --exclude-dir=vendor --exclude-dir=Corpus \
    --exclude='*.profdata' --exclude='check-secrets.sh' 2>/dev/null || true)"

if [[ -n "$HITS" ]]; then
    echo "❌ potential secrets detected:"
    echo "$HITS"
    exit 1
fi
echo "✓ no obvious secrets found"
