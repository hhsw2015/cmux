#!/usr/bin/env bash
# Fail CI when two PBXBuildFile (or PBXFileReference) lines in
# project.pbxproj share the same 24-char UUID. This catches the
# class of bug where someone hand-edits the project file and
# reuses an existing identifier — Xcode silently maps the new
# definition over the old one and the wrong file ends up in the
# wrong target, producing baffling "Compilation search paths
# unable to resolve module dependency: 'XCTest'"-style errors
# in the cmux app build.

set -euo pipefail

cd "$(dirname "$0")/.."
PROJ="cmux.xcodeproj/project.pbxproj"
if [[ ! -f "$PROJ" ]]; then
    echo "lint_pbxproj_uuid_uniqueness: $PROJ not found" >&2
    exit 1
fi

# Pull every line that defines a PBXBuildFile or PBXFileReference,
# extract the leading UUID, count duplicates.
DUPES="$(awk '
    /^[[:space:]]*[A-Z0-9]+ \/\* .* \*\/ = \{isa = (PBXBuildFile|PBXFileReference);/ {
        # Field 1 is the UUID, possibly with leading whitespace
        # already stripped by awk default FS.
        print $1
    }
' "$PROJ" | sort | uniq -d)"

if [[ -n "$DUPES" ]]; then
    echo "lint_pbxproj_uuid_uniqueness: duplicate UUIDs in $PROJ:" >&2
    while IFS= read -r uuid; do
        [[ -z "$uuid" ]] && continue
        echo "  --- $uuid ---" >&2
        grep -n "^[[:space:]]*$uuid " "$PROJ" >&2 || true
    done <<<"$DUPES"
    exit 1
fi

echo "lint_pbxproj_uuid_uniqueness: ok ($(grep -cE '^[[:space:]]*[A-Z0-9]+ /\* .* \*/ = \{isa = (PBXBuildFile|PBXFileReference);' "$PROJ") entries, all unique)"
