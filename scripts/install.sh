#!/bin/bash
# Builds an optimized GitTree and installs it into ~/Applications (or the folder you pass),
# so it shows up in Launchpad and Spotlight.
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
echo "Installed $destination/GitTree.app"
open "$destination/GitTree.app"
