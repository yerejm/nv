#!/bin/bash
set -euo pipefail

EDITOR_TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EDITOR_TEST_BUILD="$EDITOR_TEST_ROOT/build/editor-tests"
EDITOR_TEST_HELPER="$EDITOR_TEST_BUILD/acceptance-editor"
mkdir -p "$EDITOR_TEST_BUILD"
/usr/bin/xcrun clang -arch arm64 -mmacosx-version-min=15.0 -fobjc-arc -I "$EDITOR_TEST_ROOT/Tests/Support" \
    "$EDITOR_TEST_ROOT/Tests/Tools/AcceptanceEditor.m" "$EDITOR_TEST_ROOT/Tests/Support/AcceptanceEditorSession.m" \
    -framework Cocoa -o "$EDITOR_TEST_HELPER"
EDITOR_TEST_DATA="$(mktemp -d "$EDITOR_TEST_BUILD/session.XXXXXX")"
cleanup_editor_test() {
    EDITOR_TEST_STATUS=$?
    trap - EXIT
    if "$EDITOR_TEST_HELPER" --cleanup "$EDITOR_TEST_DATA"; then
        rm -f "$EDITOR_TEST_DATA/external-editor-cancelled"
    else
        EDITOR_TEST_STATUS=1
    fi
    rmdir "$EDITOR_TEST_DATA" || EDITOR_TEST_STATUS=1
    exit "$EDITOR_TEST_STATUS"
}
trap cleanup_editor_test EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
"$EDITOR_TEST_HELPER" --verify "$EDITOR_TEST_DATA"
