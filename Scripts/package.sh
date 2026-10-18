#!/bin/bash
set -euo pipefail

# create a local development zip without publishing or changing signing credentials
fileel_root="$(cd "$(dirname "$0")/.." && pwd)"
fileel_build="$fileel_root/build"
xcodebuild build -project "$fileel_root/Fileel.xcodeproj" -scheme Fileel \
    -configuration Release -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$fileel_build" CODE_SIGNING_ALLOWED=NO

fileel_app="$fileel_build/Build/Products/Release/Fileel.app"
fileel_output="$fileel_build/Fileel-development-arm64.zip"
/usr/bin/ditto -c -k --keepParent "$fileel_app" "$fileel_output"
echo "$fileel_output"
