#!/bin/bash
# Builds an optimized GitTree, installs it into ~/Applications (or the folder you pass) so it shows
# up in Launchpad and Spotlight, and installs the `gittree` command into ~/.local/bin.
#
# Usage: scripts/install.sh [destination folder]
set -euo pipefail
cd "$(dirname "$0")/.."

destination="${1:-$HOME/Applications}"
xcodebuild -project GitTree.xcodeproj -scheme GitTree -configuration Release \
    -derivedDataPath build/DerivedData build -quiet

mkdir -p "$destination"
pkill -x GitTree 2>/dev/null || true
rm -rf "$destination/GitTree.app"
ditto build/DerivedData/Build/Products/Release/GitTree.app "$destination/GitTree.app"
# Make sure gittree:// links open this copy.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$destination/GitTree.app"
echo "Installed $destination/GitTree.app"

mkdir -p "$HOME/.local/bin"
install -m 755 scripts/gittree "$HOME/.local/bin/gittree"
echo "Installed the gittree command in ~/.local/bin"

open "$destination/GitTree.app"
