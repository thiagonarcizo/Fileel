#!/bin/bash
set -euo pipefail

# package an exported app only after its distribution signature and ticket are valid
if [[ $# -ne 2 ]]; then
    echo "usage: $0 /path/to/Fileel.app /path/to/Fileel.dmg" >&2
    exit 64
fi

fileel_app="$1"
fileel_output="$2"
fileel_identity="${FILEEL_SIGNING_IDENTITY:-Developer ID Application}"
if [[ ! -d "$fileel_app" || "$fileel_output" != *.dmg ]]; then
    echo "provide an existing app bundle and a .dmg output path" >&2
    exit 64
fi
if [[ -e "$fileel_output" ]]; then
    echo "the output already exists; choose a new path" >&2
    exit 73
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$fileel_app"
fileel_signature="$(/usr/bin/codesign -dvv "$fileel_app" 2>&1)"
if [[ "$fileel_signature" != *"Authority=Developer ID Application:"* ]]; then
    echo "export the app with a Developer ID Application certificate first" >&2
    exit 65
fi
/usr/bin/xcrun stapler validate "$fileel_app"
/usr/sbin/spctl --assess --type execute --verbose=2 "$fileel_app"

# keep the notarized bundle intact and provide the usual applications shortcut
fileel_stage="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/fileel-dmg.XXXXXX")"
trap '/bin/rm -rf "$fileel_stage"' EXIT
/usr/bin/ditto "$fileel_app" "$fileel_stage/Fileel.app"
/bin/ln -s /Applications "$fileel_stage/Applications"
/bin/mkdir -p "$(/usr/bin/dirname "$fileel_output")"
/usr/bin/hdiutil create -volname Fileel -srcfolder "$fileel_stage" \
    -format UDZO -fs HFS+ "$fileel_output"
/usr/bin/codesign --sign "$fileel_identity" --timestamp "$fileel_output"
/usr/bin/codesign --verify --verbose=2 "$fileel_output"
/usr/bin/hdiutil verify "$fileel_output"
/usr/bin/shasum -a 256 "$fileel_output" > "$fileel_output.sha256"
echo "$fileel_output"
