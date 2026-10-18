#!/bin/bash
set -euo pipefail

# sign sparkle's nested executables from the inside out before sealing the parent app
if [[ $# -ne 2 || ! -d "$1/Contents" || "$2" != "Developer ID Application:"* ]]; then
    echo "usage: $0 /path/to/Fileel.app 'Developer ID Application: name (team)'" >&2
    exit 64
fi
fileel_app="$1"
fileel_identity="$2"
fileel_framework="$fileel_app/Contents/Frameworks/Sparkle.framework"
if [[ ! -d "$fileel_framework/Versions/B" ]]; then
    echo "the expected Sparkle framework is missing" >&2
    exit 65
fi
for fileel_component in \
    "$fileel_framework/Versions/B/XPCServices/Downloader.xpc" \
    "$fileel_framework/Versions/B/XPCServices/Installer.xpc" \
    "$fileel_framework/Versions/B/Updater.app" \
    "$fileel_framework/Versions/B/Autoupdate" \
    "$fileel_framework" \
    "$fileel_app"; do
    if [[ ! -e "$fileel_component" ]]; then
        echo "a required update component is missing" >&2
        exit 65
    fi
    /usr/bin/codesign --force --sign "$fileel_identity" --options runtime --timestamp \
        --preserve-metadata=entitlements "$fileel_component"
    /usr/bin/codesign --verify --strict "$fileel_component"
done
/usr/bin/codesign --verify --deep --strict "$fileel_app"
