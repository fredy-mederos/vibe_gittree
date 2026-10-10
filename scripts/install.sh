#!/bin/bash
# Builds an optimized Vibe GitTree, installs it into ~/Applications (or the folder you pass) so it shows
# up in Launchpad and Spotlight, and installs the `gittree` command into ~/.local/bin.
#
# Usage: scripts/install.sh [destination folder]
set -euo pipefail
cd "$(dirname "$0")/.."

destination="${1:-$HOME/Applications}"
# Settings › General shows these: the build number is the number of commits, the commit gets a "+"
# when there were uncommitted changes, and the build time. scripts/create_dmg.sh stamps releases the same way.
build_number=$(git rev-list --count HEAD 2>/dev/null || echo 1)
commit=$(git rev-parse --short HEAD 2>/dev/null || echo "")
if [ -n "$commit" ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then commit="$commit+"; fi
build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
xcodebuild -project GitTree.xcodeproj -scheme GitTree -configuration Release \
    -derivedDataPath build/DerivedData CURRENT_PROJECT_VERSION="$build_number" GT_BUILD_COMMIT="$commit" \
    GT_BUILD_DATE="$build_date" build -quiet

mkdir -p "$destination"
# Copies installed before the app was renamed (GitTree.app) are replaced too.
pkill -x "Vibe GitTree" 2>/dev/null || true
pkill -x GitTree 2>/dev/null || true
rm -rf "$destination/Vibe GitTree.app" "$destination/GitTree.app"
ditto "build/DerivedData/Build/Products/Release/Vibe GitTree.app" "$destination/Vibe GitTree.app"
# Make sure gittree:// links open this copy.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$destination/Vibe GitTree.app"
echo "Installed $destination/Vibe GitTree.app (build $build_number${commit:+, $commit})"

mkdir -p "$HOME/.local/bin"
install -m 755 scripts/gittree "$HOME/.local/bin/gittree"
echo "Installed the gittree command in ~/.local/bin"

open "$destination/Vibe GitTree.app"
