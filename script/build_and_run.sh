#!/bin/bash
set -euo pipefail

RUN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_MODE="${1:-run}"
case "$RUN_MODE" in
    run|--debug|--logs|--telemetry|--verify) ;;
    *) echo "usage: $0 [--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac
RUN_DATA="$RUN_ROOT/build/isolated-run"
RUN_APP="$RUN_ROOT/build/isolated-app/Notational Velocity Development.app"
RUN_BUNDLE_ID=net.notational.velocity.development
if [[ "$RUN_MODE" == --verify ]]; then
    # A separate identity lets every acceptance run start from empty defaults without touching the development app's settings.
    RUN_APP="$RUN_ROOT/build/acceptance-app/Notational Velocity Development.app"
    RUN_BUNDLE_ID=net.notational.velocity.development.acceptance
fi
RUN_EXECUTABLE="$RUN_APP/Contents/MacOS/NVDevelopment"
RUN_LIBRARY="$RUN_ROOT/build/isolated-launch.dylib"
RUN_EDITOR_HELPER="$RUN_ROOT/build/acceptance-editor"

/usr/bin/pkill -x NVDevelopment >/dev/null 2>&1 || true
/usr/bin/xcodebuild -project "$RUN_ROOT/Notation.xcodeproj" -scheme Notation \
    -configuration Development -derivedDataPath "$RUN_ROOT/build/app" \
    CODE_SIGNING_ALLOWED=NO build
if [[ "$RUN_MODE" == --verify ]]; then
    RUN_DATA="$(mktemp -d "$RUN_ROOT/build/acceptance.XXXXXX")"
fi
mkdir -p "$(dirname "$RUN_APP")" "$RUN_DATA/notes" "$RUN_DATA/tmp"
if [[ ! -f "$RUN_DATA/notes/Notes & Settings" ]]; then
    cp "$RUN_ROOT/Tests/Fixtures/legacy-plain.database" "$RUN_DATA/notes/Notes & Settings"
fi
rm -rf "$RUN_APP"
/usr/bin/ditto "$RUN_ROOT/build/app/Build/Products/Development/Notational Velocity.app" "$RUN_APP"
mv "$RUN_APP/Contents/MacOS/Notational Velocity" "$RUN_EXECUTABLE"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $RUN_BUNDLE_ID" "$RUN_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable NVDevelopment' "$RUN_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :CFBundleURLTypes' "$RUN_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :NSServices' "$RUN_APP/Contents/Info.plist"
# The hardened runtime matches release builds; the extra entitlements only admit the injected isolation library.
/usr/bin/codesign --force --sign - --options runtime --entitlements "$RUN_ROOT/Tests/Tools/IsolatedLaunch.entitlements" \
    --identifier "$RUN_BUNDLE_ID" "$RUN_APP"
RUN_INCLUDE_FLAGS=()
while IFS= read -r RUN_INCLUDE_DIRECTORY; do
    RUN_INCLUDE_FLAGS+=(-I "$RUN_INCLUDE_DIRECTORY")
done < <(/usr/bin/python3 "$RUN_ROOT/Tests/Tools/project_layout.py")
/usr/bin/xcrun clang -arch arm64 -mmacosx-version-min=15.0 -fobjc-arc -dynamiclib -undefined dynamic_lookup \
    "${RUN_INCLUDE_FLAGS[@]}" \
    "$RUN_ROOT/Tests/Tools/IsolatedLaunch.m" "$RUN_ROOT/Tests/Support/AcceptanceEditorSession.m" \
    -framework Cocoa -framework Carbon -o "$RUN_LIBRARY"
RUN_ENV=(--env "DYLD_INSERT_LIBRARIES=$RUN_LIBRARY" --env "NV_ISOLATED_ROOT=$RUN_DATA" --env "TMPDIR=$RUN_DATA/tmp/")
if [[ "$RUN_MODE" == --verify ]]; then
    /usr/bin/xcrun clang -arch arm64 -mmacosx-version-min=15.0 -fobjc-arc "${RUN_INCLUDE_FLAGS[@]}" \
        "$RUN_ROOT/Tests/Tools/AcceptanceEditor.m" "$RUN_ROOT/Tests/Support/AcceptanceEditorSession.m" \
        -framework Cocoa -o "$RUN_EDITOR_HELPER"
    cleanup_acceptance() {
        RUN_EXIT_STATUS=$?
        trap - EXIT
        "$RUN_EDITOR_HELPER" --cleanup "$RUN_DATA" || { echo "External editor teardown failed: $RUN_DATA" >&2; RUN_EXIT_STATUS=1; }
        while IFS= read -r RUN_CACHE_DEVICE; do
            /sbin/umount "$RUN_DATA/tmp/NVProtectedEditingSpace" || RUN_EXIT_STATUS=1
            /usr/bin/hdiutil detach "$RUN_CACHE_DEVICE" || RUN_EXIT_STATUS=1
        done < <(/sbin/mount | /usr/bin/awk -v cache="$RUN_DATA/tmp/NVProtectedEditingSpace" 'index($0, " on " cache " (") { devices[++count]=$1 } END { for(i=count;i>0;i--) print devices[i] }')
        exit "$RUN_EXIT_STATUS"
    }
    trap cleanup_acceptance EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    rm -f "$RUN_DATA/result.json"
    /usr/bin/defaults delete "$RUN_BUNDLE_ID" >/dev/null 2>&1 || true
    rm -rf "$HOME/Library/Saved Application State/$RUN_BUNDLE_ID.savedState"
    RUN_ENV+=(--env NV_AUTOMATED_ACCEPTANCE=YES)
fi
if [[ "$RUN_MODE" == --debug ]]; then
    NV_ISOLATED_ROOT="$RUN_DATA" DYLD_INSERT_LIBRARIES="$RUN_LIBRARY" /usr/bin/xcrun lldb -- "$RUN_EXECUTABLE"
    exit
fi
/usr/bin/open -n "${RUN_ENV[@]}" "$RUN_APP"
case "$RUN_MODE" in
    --logs|--telemetry)
        /usr/bin/log stream --info --debug --style compact --predicate 'process == "NVDevelopment"'
        ;;
    --verify)
        RUN_FAILED=0
        for ((attempt=0; attempt<60; attempt++)); do
            if [[ -f "$RUN_DATA/result.json" ]]; then
                if /usr/bin/python3 -c 'import json,sys; sys.exit("externalPrerequisite" not in json.load(open(sys.argv[1])))' "$RUN_DATA/result.json"; then
                    /usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["externalPrerequisite"])' "$RUN_DATA/result.json" >&2
                    exit 75
                fi
                /usr/bin/python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d,indent=2)); sys.exit(any(not c["passed"] for c in d["checks"]))' "$RUN_DATA/result.json" || RUN_FAILED=1
                break
            fi
            sleep 1
        done
        [[ -f "$RUN_DATA/result.json" ]] || { echo "Acceptance result did not arrive: $RUN_DATA" >&2; exit 1; }
        for ((attempt=0; attempt<10; attempt++)); do
            if ! /usr/bin/pgrep -x NVDevelopment >/dev/null; then break; fi
            sleep 1
        done
        if /sbin/mount | /usr/bin/grep -qF " on $RUN_DATA/tmp/NVProtectedEditingSpace ("; then
            echo "The external-editing RAM disk is still mounted after quitting." >&2
            RUN_FAILED=1
        fi
        /usr/bin/open -n "${RUN_ENV[@]}" --env NV_REOPEN_ACCEPTANCE=YES "$RUN_APP"
        for ((attempt=0; attempt<45; attempt++)); do
            if [[ -f "$RUN_DATA/reopen-result.json" ]]; then
                /usr/bin/python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d,indent=2)); sys.exit(any(not c["passed"] for c in d["checks"]))' "$RUN_DATA/reopen-result.json" || RUN_FAILED=1
                for ((quit_attempt=0; quit_attempt<10; quit_attempt++)); do
                    if ! /usr/bin/pgrep -x NVDevelopment >/dev/null; then break; fi
                    sleep 1
                done
                if [[ "$RUN_FAILED" == 1 ]] && /usr/bin/python3 -c 'import json,sys; sys.exit(not json.load(open(sys.argv[1])).get("activationRefused"))' "$RUN_DATA/result.json"; then
                    echo "macOS declined to activate the app, so another app was likely in use; rerun with the desktop idle." >&2
                    exit 75
                fi
                exit "$RUN_FAILED"
            fi
            sleep 1
        done
        echo "Reopen result did not arrive: $RUN_DATA" >&2
        exit 1
        ;;
esac
