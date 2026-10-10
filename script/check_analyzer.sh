#!/bin/bash
# Runs the Clang static analyzer over a clean build of the app and fails on any finding.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT/build/analyze"
LOG="$DERIVED_DATA/analyze.log"

mkdir -p "$DERIVED_DATA"
if ! /usr/bin/xcodebuild -project "$ROOT/Notation.xcodeproj" -scheme Notation -configuration Development \
    -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO clean analyze >"$LOG" 2>&1; then
    tail -n 30 "$LOG" >&2
    echo "Static analysis failed; see $LOG" >&2
    exit 1
fi

findings="$(grep -E ': warning: ' "$LOG" | sed "s|^$ROOT/||" | sort -u || true)"
if [ -n "$findings" ]; then
    echo "$findings" >&2
    echo "Static analyzer findings: $(grep -c . <<<"$findings")" >&2
    exit 1
fi
echo "No static analyzer findings."
