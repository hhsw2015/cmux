#!/usr/bin/env bash
# Remove tagged Xcode DerivedData directories (cmux-<tag>) except the ones
# passed on the command line. Recovers ~5 GB per tag.
#
# Usage:
#   ./scripts/cleanup-derived-data.sh                    # remove ALL cmux-* dirs
#   ./scripts/cleanup-derived-data.sh p73-merge          # keep only cmux-p73-merge
#   ./scripts/cleanup-derived-data.sh p73-merge p74-fix  # keep multiple
set -euo pipefail

DERIVED_ROOT="$HOME/Library/Developer/Xcode/DerivedData"
keep=("$@")

should_keep() {
  local name=$1
  for k in "${keep[@]:-}"; do
    [[ "$name" == "cmux-$k" ]] && return 0
  done
  return 1
}

freed=0
for dir in "$DERIVED_ROOT"/cmux-*; do
  [[ -d "$dir" ]] || continue
  base=$(basename "$dir")
  if should_keep "$base"; then
    echo "keep: $dir"
    continue
  fi
  size=$(du -sk "$dir" 2>/dev/null | cut -f1)
  echo "remove: $dir ($((size / 1024)) MB)"
  rm -rf "$dir"
  freed=$((freed + size))
done

echo "freed: $((freed / 1024)) MB"
