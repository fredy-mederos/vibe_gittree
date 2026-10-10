#!/bin/bash
# Builds Vibe GitTree (Release, for Apple silicon and Intel), signs it with a Developer ID and packs it into
# build/VibeGitTree.dmg, signed too. scripts/release.sh runs this, then scripts/notarize_dmg.sh.
#
# Usage: APP_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/create_dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

: "${APP_SIGN_IDENTITY:?Set APP_SIGN_IDENTITY, e.g. \"Developer ID Application: Your Name (TEAMID)\"}"

name="Vibe GitTree"
derived="build/release/DerivedData"
app="$derived/Build/Products/Release/$name.app"
staging="build/release/dmg"
dmg="build/VibeGitTree.dmg"

# A release is built from a commit: Settings › General shows its hash, with "+" for uncommitted changes.
if [ -n "$(git status --porcelain)" ] && [ -z "${ALLOW_DIRTY:-}" ]; then
    echo "There are uncommitted changes. Commit them first, or set ALLOW_DIRTY=1 for a test build." >&2
    exit 1
fi
build_number=$(git rev-list --count HEAD)
commit=$(git rev-parse --short HEAD)
if [ -n "$(git status --porcelain)" ]; then commit="$commit+"; fi
build_date=$(date -u +%Y-%m-%dT%H:%M:%SZ)

rm -rf "$derived"
xcodebuild -project GitTree.xcodeproj -scheme GitTree -configuration Release -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived" CURRENT_PROJECT_VERSION="$build_number" GT_BUILD_COMMIT="$commit" \
    GT_BUILD_DATE="$build_date" build -quiet

# The Developer ID signature, with the hardened runtime and a secure timestamp: notarization requires both.
codesign --force --options runtime --timestamp --sign "$APP_SIGN_IDENTITY" "$app"
codesign --verify --deep --strict "$app"

rm -rf "$staging" "$dmg"
mkdir -p "$staging"
ditto "$app" "$staging/$name.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "$name" -srcfolder "$staging" -format UDZO -imagekey zlib-level=9 -quiet "$dmg"
codesign --force --timestamp --sign "$APP_SIGN_IDENTITY" "$dmg"
rm -rf "$staging"

version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")
echo "Created $dmg: $name $version (build $build_number, $commit)"
