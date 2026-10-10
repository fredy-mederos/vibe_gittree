#!/bin/bash
# Builds, signs, notarizes and staples build/GitTree.dmg, ready to attach to a GitHub release. The release-gittree
# skill (skills/release-gittree) runs this as one step of a whole release.
#
# Usage: APP_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_KEYCHAIN_PROFILE=<profile> scripts/release.sh
set -euo pipefail
scripts="$(cd "$(dirname "$0")" && pwd)"

"$scripts/create_dmg.sh"
"$scripts/notarize_dmg.sh"
