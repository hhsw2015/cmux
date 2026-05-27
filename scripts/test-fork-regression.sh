#!/usr/bin/env bash
# Run ForkRegressionTests locally to verify fork-only behavior survived
# the latest upstream merge. Bypasses zig + uses the fork's prebuilt
# GhosttyKit xcframework. Pass --all to run the full cmuxTests target
# instead of only ForkRegressionTests.
set -euo pipefail

DERIVED="/tmp/cmux-test-build"
ONLY="-only-testing:cmuxTests/ForkRegressionTests"
for arg in "$@"; do
  case "$arg" in
    --all) ONLY="" ;;
    --clean) rm -rf "$DERIVED" ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

CMUX_GHOSTTYKIT_REPO=hhsw2015/ghostty \
CMUX_SKIP_ZIG_BUILD=1 \
xcodebuild \
  -project cmux.xcodeproj \
  -scheme cmux-unit \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY=- \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  $ONLY \
  test 2>&1 | grep -E "Test Case|Executed [0-9]|error:" | grep -v "find module\|no such module\|cannot load module"
