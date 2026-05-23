#!/usr/bin/env bash
#
# Bundle cmux-tmux into the cmux .app's Resources/bin directory.
#
# cmux-tmux is the in-tree Rust shim that lets cmux drive an
# existing tmux server (see tools/cmux-tmux). Bundling it means
# users who choose the "Local tmux" backend in Settings don't need
# to install anything separately.
#
# Source resolution order:
#   1. $CMUX_TMUX_BIN                   (explicit path, primarily CI)
#   2. tools/cmux-tmux/target/release/cmux-tmux
#      (built by `cargo build --release` in the workspace root —
#      reload.sh / CI run this before the Xcode build)
#   3. ~/.local/bin/cmux-tmux           (manual dev install)
#   4. None — warn, don't fail. Settings dialog can still pin
#      a path manually; SSH hosts will use the auto-installer.
#
# Output: $TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/bin/cmux-tmux
set -euo pipefail

DEST_DIR="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/bin"
DEST="${DEST_DIR}/cmux-tmux"

mkdir -p "$DEST_DIR"

resolve_source() {
  if [ -n "${CMUX_TMUX_BIN:-}" ] && [ -x "$CMUX_TMUX_BIN" ]; then
    echo "$CMUX_TMUX_BIN"
    return
  fi
  if [ -x "${SRCROOT}/tools/cmux-tmux/target/release/cmux-tmux" ]; then
    echo "${SRCROOT}/tools/cmux-tmux/target/release/cmux-tmux"
    return
  fi
  if [ -x "$HOME/.local/bin/cmux-tmux" ]; then
    echo "$HOME/.local/bin/cmux-tmux"
    return
  fi
  echo ""
}

SRC="$(resolve_source)"

if [ -z "$SRC" ]; then
  echo "warning: cmux-tmux not found; the 'Local tmux' backend will fall back to looking up cmux-tmux on \$PATH at runtime" >&2
  rm -f "$DEST"
  exit 0
fi

rm -f "$DEST"
cp "$SRC" "$DEST"
chmod +x "$DEST"
echo "Bundled cmux-tmux from: $SRC"
