#!/bin/bash
# Like snapshot.sh, but captures Vibe GitTree's window once for each sidebar row -GTSelect names
# (comma-separated), as the app selects them one after another. Handy for checking how selected
# rows look in light and dark mode.
#
# Usage:   scripts/snapshot-rows.sh <output-prefix> [app arguments...]
# Example: scripts/snapshot-rows.sh /tmp/rows -GTOpenRepository ~/code/some-repo -GTAppearance dark -GTSelect "ref:main,pr:open"
# Writes <output-prefix>-1.png, <output-prefix>-2.png… Vibe GitTree has to stay in front meanwhile.
set -euo pipefail
cd "$(dirname "$0")/.."

out="$1"
shift

rows=""
previous=""
for argument in "$@"; do
    [ "$previous" = "-GTSelect" ] && rows="$argument"
    previous="$argument"
done
if [ -z "$rows" ]; then
    echo "Name the rows with -GTSelect" >&2
    exit 1
fi
count=$(echo "$rows" | tr ',' '\n' | wc -l | tr -d ' ')

app="build/DerivedData/Build/Products/Debug/Vibe GitTree.app"
data="${GT_DATA_DIR:-$(mktemp -d)}"
# The app writes <n>.selected once row n is drawn and waits for <n>.captured before the next.
markers="$(mktemp -d)"

pkill -x "Vibe GitTree" 2>/dev/null || true
sleep 0.5
open -n "$app" --args -GTDataDirectory "$data" -ApplePersistenceIgnoreState YES -GTSelectMarkers "$markers" "$@"

for n in $(seq 1 "$count"); do
    for _ in $(seq 1 240); do
        [ -f "$markers/$n.selected" ] && break
        sleep 0.25
    done
    if [ ! -f "$markers/$n.selected" ]; then
        echo "Row $n wasn't selected within a minute" >&2
        exit 1
    fi
    id=$(swift scripts/window-id.swift "Vibe GitTree")
    if [ "$id" = "0" ]; then
        echo "Vibe GitTree has no window on screen" >&2
        exit 1
    fi
    screencapture -x -o -l "$id" "$out-$n.png"
    touch "$markers/$n.captured"
    echo "$out-$n.png"
done
