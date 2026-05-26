#!/usr/bin/env bash
# Build Release cmux.app locally without zig (uses prebuilt GhosttyKit
# from hhsw2015/ghostty fork), then re-sign + clear quarantine so the
# adhoc signature survives Gatekeeper.
#
# Usage:
#   ./scripts/build-release-local.sh           # build only
#   ./scripts/build-release-local.sh --install # build + replace /Applications/cmux.app
set -euo pipefail

INSTALL=0
for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    *) echo "unknown arg: $arg" >&2; exit 1 ;;
  esac
done

DERIVED="/tmp/cmux-release-merge"
APP_SRC="$DERIVED/Build/Products/Release/cmux.app"
APP_DST="/Applications/cmux.app"

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

if [[ ! -d "$APP_SRC" ]]; then
  echo "error: build did not produce $APP_SRC" >&2
  exit 1
fi

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
