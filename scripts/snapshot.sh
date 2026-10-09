#!/bin/bash
# Launches the Debug build with a throwaway repository library and captures only GitTree's window.
# Handy for checking UI changes without touching your real library.
#
# Usage:   scripts/snapshot.sh <output.png> <seconds-to-wait> [app arguments...]
# Example: scripts/snapshot.sh /tmp/graph.png 6 -GTOpenRepository ~/code/some-repo -GTSearch "fix"
#
# Debug-only app arguments: -GTOpenRepository <path>, -GTCloneURL <url>, -GTSearch <text>.
# Set GT_DATA_DIR to reuse a library between runs; otherwise each run starts empty.
set -euo pipefail
cd "$(dirname "$0")/.."

out="$1"
wait="$2"
shift 2

app="build/DerivedData/Build/Products/Debug/GitTree.app"
data="${GT_DATA_DIR:-$(mktemp -d)}"

pkill -x GitTree 2>/dev/null || true
sleep 0.5
open -n "$app" --args -GTDataDirectory "$data" -ApplePersistenceIgnoreState YES "$@"
sleep "$wait"

id=$(swift scripts/window-id.swift GitTree)
if [ "$id" = "0" ]; then
    echo "GitTree has no window on screen" >&2
    exit 1
fi
screencapture -x -o -l "$id" "$out"
echo "$out"
