#!/usr/bin/env bash
# Build Release cmux.app locally without zig (uses prebuilt GhosttyKit
# from hhsw2015/ghostty fork), then re-sign + clear quarantine so the
# adhoc signature survives Gatekeeper.
#
# By default the 5+ GB Xcode DerivedData at /tmp/cmux-release-merge is
# deleted after the build. The built .app is staged to /tmp/cmux-release
# (small — the .app itself, ~500 MB unpacked) for DMG packaging.
# Pass --keep-derived to retain the raw build tree for incremental rebuilds.
#
# Usage:
#   ./scripts/build-release-local.sh                 # build, stage, drop DerivedData
#   ./scripts/build-release-local.sh --install       # build + replace /Applications/cmux.app
#   ./scripts/build-release-local.sh --keep-derived  # keep /tmp/cmux-release-merge
set -euo pipefail

INSTALL=0
KEEP_DERIVED=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --keep-derived) KEEP_DERIVED=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

DERIVED="/tmp/cmux-release-merge"
BUILD_APP="$DERIVED/Build/Products/Release/cmux.app"
STAGE_DIR="/tmp/cmux-release"
APP_SRC="$STAGE_DIR/cmux.app"
APP_DST="/Applications/cmux.app"

cleanup_derived() {
  if [[ "$KEEP_DERIVED" -eq 1 ]]; then return; fi
  if [[ -d "$DERIVED" ]]; then
    echo "==> Cleaning $DERIVED (build artifacts)"
    rm -rf "$DERIVED"
  fi
}
trap cleanup_derived EXIT

echo "==> Building Release cmux.app (skipping zig, using fork ghostty xcframework)"
CMUX_GHOSTTYKIT_REPO=hhsw2015/ghostty \
CMUX_SKIP_ZIG_BUILD=1 \
xcodebuild \
  -project cmux.xcodeproj \
  -scheme cmux \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  build | tail -5

if [[ ! -d "$BUILD_APP" ]]; then
  echo "error: build did not produce $BUILD_APP" >&2
  exit 1
fi

echo "==> Staging to $APP_SRC"
mkdir -p "$STAGE_DIR"
rm -rf "$APP_SRC"
cp -R "$BUILD_APP" "$APP_SRC"

echo "==> Re-signing adhoc"
codesign --force --deep --sign - "$APP_SRC"

echo "==> Built: $APP_SRC"

if [[ "$INSTALL" -eq 1 ]]; then
  echo "==> Installing to $APP_DST (sudo required)"
  sudo pkill -x cmux 2>/dev/null || true
  sleep 0.3
  if [[ -d "$APP_DST" ]]; then
    sudo mv "$APP_DST" "${APP_DST}.bak.$(date +%s)"
  fi
  sudo cp -R "$APP_SRC" "$APP_DST"
  sudo xattr -cr "$APP_DST"
  sudo codesign --force --deep --sign - "$APP_DST"
  echo "==> Installed. Launch with: open $APP_DST"
else
  echo ""
  echo "To install:"
  echo "  $0 --install"
  echo "Or manually:"
  echo "  pkill -x cmux"
  echo "  sudo mv /Applications/cmux.app /Applications/cmux.app.bak"
  echo "  sudo cp -R '$APP_SRC' /Applications/"
  echo "  sudo xattr -cr /Applications/cmux.app"
  echo "  sudo codesign --force --deep --sign - /Applications/cmux.app"
  echo "  open /Applications/cmux.app"
fi
