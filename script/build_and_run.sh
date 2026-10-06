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
RUN_EXECUTABLE="$RUN_APP/Contents/MacOS/NVDevelopment"
RUN_LIBRARY="$RUN_ROOT/build/isolated-launch.dylib"

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
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier net.notational.velocity.development' "$RUN_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable NVDevelopment' "$RUN_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :CFBundleURLTypes' "$RUN_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Delete :NSServices' "$RUN_APP/Contents/Info.plist"
/usr/bin/codesign --force --sign - --identifier net.notational.velocity.development "$RUN_APP"
RUN_INCLUDE_FLAGS=()
while IFS= read -r RUN_INCLUDE_DIRECTORY; do
    RUN_INCLUDE_FLAGS+=(-I "$RUN_INCLUDE_DIRECTORY")
done < <(/usr/bin/python3 "$RUN_ROOT/Tests/Tools/project_layout.py")
/usr/bin/xcrun clang -arch arm64 -mmacosx-version-min=15.0 -dynamiclib -undefined dynamic_lookup \
    "${RUN_INCLUDE_FLAGS[@]}" \
    "$RUN_ROOT/Tests/Tools/IsolatedLaunch.m" -framework Cocoa -framework Carbon -o "$RUN_LIBRARY"
RUN_ENV=(--env "DYLD_INSERT_LIBRARIES=$RUN_LIBRARY" --env "NV_ISOLATED_ROOT=$RUN_DATA" --env "TMPDIR=$RUN_DATA/tmp/")
if [[ "$RUN_MODE" == --verify ]]; then
    rm -f "$RUN_DATA/result.json"
    RUN_ENV+=(--env NV_AUTOMATED_ACCEPTANCE=YES)
fi
if [[ "$RUN_MODE" == --debug ]]; then
    NV_ISOLATED_ROOT="$RUN_DATA" DYLD_INSERT_LIBRARIES="$RUN_LIBRARY" /usr/bin/xcrun lldb -- "$RUN_EXECUTABLE"
    exit
fi
/usr/bin/open -n "${RUN_ENV[@]}" "$RUN_APP"
case "$RUN_MODE" in
    --logs|--telemetry)
        /usr/bin/log stream --info --style compact --predicate 'process == "NVDevelopment"'
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
        /usr/bin/open -n "${RUN_ENV[@]}" --env NV_REOPEN_ACCEPTANCE=YES "$RUN_APP"
        for ((attempt=0; attempt<45; attempt++)); do
            if [[ -f "$RUN_DATA/reopen-result.json" ]]; then
                /usr/bin/python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d,indent=2)); sys.exit(any(not c["passed"] for c in d["checks"]))' "$RUN_DATA/reopen-result.json" || RUN_FAILED=1
                for ((quit_attempt=0; quit_attempt<10; quit_attempt++)); do
                    if ! /usr/bin/pgrep -x NVDevelopment >/dev/null; then break; fi
                    sleep 1
                done
                while IFS= read -r RUN_CACHE_DEVICE; do
                    /sbin/umount "$RUN_DATA/tmp/NVProtectedEditingSpace" || RUN_FAILED=1
                    /usr/bin/hdiutil detach "$RUN_CACHE_DEVICE" || RUN_FAILED=1
                done < <(/sbin/mount | /usr/bin/awk -v cache="$RUN_DATA/tmp/NVProtectedEditingSpace" 'index($0, " on " cache " (") { devices[++count]=$1 } END { for(i=count;i>0;i--) print devices[i] }')
                exit "$RUN_FAILED"
            fi
            sleep 1
        done
        echo "Reopen result did not arrive: $RUN_DATA" >&2
        exit 1
        ;;
esac
