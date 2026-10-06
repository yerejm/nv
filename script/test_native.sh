#!/bin/bash
set -euo pipefail
TEST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
/usr/bin/xcodebuild -project "$TEST_ROOT/Tests/NativeIntegration.xcodeproj" \
    -scheme NativeIntegration -configuration Debug -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$TEST_ROOT/build/native-tests" CODE_SIGNING_ALLOWED=NO test "$@"
