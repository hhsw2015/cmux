#!/usr/bin/env bash
#
# Bundle herdr-cmux into the cmux .app's Resources/bin directory.
#
# Source resolution order:
#   1. $HERDR_CMUX_BIN     (explicit path, primarily for CI)
#   2. ~/.local/bin/herdr-cmux  (where the dev typically installs)
#   3. /Users/wowdd1/Dev/herdr/target/release/herdr-cmux (dev fork)
#   4. None — emit a warning, do not fail the build. Users get the
#      "missing local binary" alert which links to build instructions.
#
# Output: $TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/bin/herdr-cmux
set -euo pipefail

DEST_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/bin"
DEST="${DEST_DIR}/herdr-cmux"

mkdir -p "$DEST_DIR"

resolve_source() {
  if [ -n "${HERDR_CMUX_BIN:-}" ] && [ -x "$HERDR_CMUX_BIN" ]; then
    echo "$HERDR_CMUX_BIN"
    return
  fi
  if [ -x "$HOME/.local/bin/herdr-cmux" ]; then
    echo "$HOME/.local/bin/herdr-cmux"
    return
  fi
  if [ -x "/Users/wowdd1/Dev/herdr/target/release/herdr-cmux" ]; then
    echo "/Users/wowdd1/Dev/herdr/target/release/herdr-cmux"
    return
  fi
  echo ""
}

SRC="$(resolve_source)"

if [ -z "$SRC" ]; then
  echo "warning: herdr-cmux not found; cmux will fall back to ~/.local/bin/herdr-cmux at runtime" >&2
  rm -f "$DEST"
  exit 0
fi

rm -f "$DEST"
cp "$SRC" "$DEST"
chmod +x "$DEST"
echo "Bundled herdr-cmux from: $SRC"
