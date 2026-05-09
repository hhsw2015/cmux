#!/bin/bash
set -e

# cmux 本地编译脚本
# 用法:
#   bash build.sh          # 编译 + 安装到 /Applications + 清理
#   bash build.sh --clean  # 只清理, 不编译

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

CLEAN_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN_ONLY=true ;;
  esac
done

cleanup() {
  echo "=== Cleaning build artifacts ==="
  rm -rf build
  echo "  build/ removed (~1.3GB)"

  rm -rf .spm-cache
  echo "  .spm-cache/ removed (~2.6GB)"

  rm -rf GhosttyKit.xcframework
  echo "  GhosttyKit.xcframework removed (~536MB)"

  rm -rf .zig
  echo "  .zig/ removed (zig toolchain)"

  # ghostty submodule: deinit to free space
  git submodule deinit -f ghostty 2>/dev/null && echo "  ghostty submodule deinited (~538MB)" || true

  echo "=== Cleanup done (freed ~5GB) ==="
}

if [ "$CLEAN_ONLY" = true ]; then
  cleanup
  exit 0
fi

echo "=== Step 1: Init submodules ==="
git submodule update --init --recursive

echo "=== Step 2: Install zig ==="
bash scripts/install-zig-ci.sh
export PATH="$SCRIPT_DIR/.zig:$PATH"

echo "=== Step 3: Download GhosttyKit ==="
bash scripts/download-prebuilt-ghosttykit.sh

echo "=== Step 4: Check Metal Toolchain ==="
if ! xcrun metal --version >/dev/null 2>&1; then
  echo "Installing Metal Toolchain (one-time, ~700MB)..."
  xcodebuild -downloadComponent MetalToolchain
fi

echo "=== Step 5: Build (arm64, unsigned) ==="
xcodebuild -scheme cmux -configuration Release -derivedDataPath build \
  -destination 'generic/platform=macOS' \
  -clonedSourcePackagesDirPath .spm-cache \
  ARCHS="arm64" \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  build 2>&1 | grep -E "^(\*\*|error:)" | tail -5

if [ ! -d "build/Build/Products/Release/cmux.app" ]; then
  echo "ERROR: Build failed"
  exit 1
fi

echo "=== Step 6: Install to /Applications ==="
osascript -e 'quit app "cmux"' 2>/dev/null || true
sleep 2
rm -rf /Applications/cmux.app
cp -R build/Build/Products/Release/cmux.app /Applications/cmux.app
echo "  Installed: /Applications/cmux.app"

echo "=== Step 7: Launch ==="
open /Applications/cmux.app


echo ""
echo "=== Done ==="
echo "  Version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' /Applications/cmux.app/Contents/Info.plist) ($(git rev-parse --short HEAD))"
echo "  Note: Metal Toolchain (~700MB) is system-level, not auto-cleaned."
echo "        Remove manually: xcodebuild -downloadComponent MetalToolchain (re-download when needed)"
