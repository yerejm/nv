#!/bin/bash
# Builds the app with Apple's soft deprecations (API_TO_BE_DEPRECATED) promoted to deprecations and fails on any
# deprecated API use outside the allowlist.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT/build/deprecations"
LOG="$DERIVED_DATA/build.log"
# Extended regular expressions matched against "path:line:column: warning: ..." lines.
ALLOWED=(
    # Faux italic for fonts without an italic face has no replacement.
    "'NSObliquenessAttributeName' is deprecated"
    # The hot key, menu bar icon and nv: links must take focus; cooperative activation can decline it.
    "^Sources/Application/AppController\\.m:[0-9]+:[0-9]+: warning: 'activateIgnoringOtherApps:' is deprecated"
)

mkdir -p "$DERIVED_DATA"
if ! /usr/bin/xcodebuild -project "$ROOT/Notation.xcodeproj" -scheme Notation -configuration Development \
    -derivedDataPath "$DERIVED_DATA" CODE_SIGNING_ALLOWED=NO \
    "OTHER_CFLAGS=\$(inherited) -DAPI_TO_BE_DEPRECATED=10.0 -DAPI_TO_BE_DEPRECATED_MACOS=10.0" \
    clean build >"$LOG" 2>&1; then
    tail -n 30 "$LOG" >&2
    echo "Soft-deprecation build failed; see $LOG" >&2
    exit 1
fi

deprecations="$(grep -E 'warning: .*\[-Wdeprecated' "$LOG" | sed "s|^$ROOT/||" | sort -u || true)"
unexpected="$deprecations"
for pattern in "${ALLOWED[@]}"; do
    unexpected="$(grep -vE "$pattern" <<<"$unexpected" || true)"
done

if [ -n "$unexpected" ]; then
    echo "$unexpected" >&2
    echo "Deprecated API use outside the allowlist: $(grep -c . <<<"$unexpected") site(s)" >&2
    exit 1
fi
echo "No deprecated API use outside the allowlist ($(grep -c . <<<"$deprecations" || true) allowlisted site(s))."
