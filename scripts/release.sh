#!/bin/bash
# Builds, signs, notarizes and staples build/VibeGitTree.dmg, ready to attach to a GitHub release. The
# release-vibe-gittree skill (skills/release-vibe-gittree) runs this as one step of a whole release.
#
# Usage: APP_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_KEYCHAIN_PROFILE=<profile> scripts/release.sh
set -euo pipefail
scripts="$(cd "$(dirname "$0")" && pwd)"

"$scripts/create_dmg.sh"
"$scripts/notarize_dmg.sh"
