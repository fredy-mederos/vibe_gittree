#!/bin/bash
# Prints GitTree's version (MARKETING_VERSION in the Xcode project), or sets it: scripts/version.sh 0.2.0
set -euo pipefail
cd "$(dirname "$0")/.."

project="GitTree.xcodeproj/project.pbxproj"

if [ $# -gt 0 ]; then
    if ! [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "Use a version like 1.2.0" >&2
        exit 1
    fi
    sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $1;/" "$project"
fi

versions=$(sed -n -E 's/.*MARKETING_VERSION = ([^;]+);/\1/p' "$project" | sort -u)
if [ "$(printf '%s\n' "$versions" | grep -c .)" -ne 1 ]; then
    echo "The project's targets have different versions: $(echo $versions)" >&2
    exit 1
fi
echo "$versions"
