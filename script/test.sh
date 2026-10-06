#!/bin/bash
set -euo pipefail
TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DERIVED_DATA="${NV_TEST_DERIVED_DATA:-$TEST_ROOT/build/tests}"
/usr/bin/python3 "$TEST_ROOT/Tests/Tools/extract_units.py"
/usr/bin/xcodebuild -project "$TEST_ROOT/Tests/Compatibility.xcodeproj" \
    -scheme Compatibility -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$TEST_DERIVED_DATA" CODE_SIGNING_ALLOWED=NO test "$@"
