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
fileel_channel="${FILEEL_RELEASE_CHANNEL:-stable}"
fileel_root="$(cd "$(dirname "$0")/.." && pwd)"
fileel_python="${FILEEL_DMG_PYTHON:-$fileel_root/build/dmg-tools/bin/python3}"
if [[ "$fileel_channel" != stable && "$fileel_channel" != beta ]]; then
    echo "choose stable or beta for the installer channel" >&2
    exit 64
fi
if [[ ! -x "$fileel_python" ]]; then
    echo "install the pinned Distribution/dmg-requirements.txt in build/dmg-tools first" >&2
    exit 69
fi
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

# keep the notarized bundle intact while authoring finder metadata on the mounted volume
fileel_stage="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/fileel-dmg.XXXXXX")"
fileel_mount="$fileel_stage/volume"
fileel_mounted=false
fileel_cleanup() {
    if [[ "$fileel_mounted" == true ]]; then
        /usr/bin/hdiutil detach "$fileel_mount" >/dev/null || true
    fi
    /bin/rm -rf "$fileel_stage"
}
trap fileel_cleanup EXIT
fileel_volume=Fileel
if [[ "$fileel_channel" == beta ]]; then fileel_volume="Fileel Beta"; fi
fileel_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$fileel_app/Contents/Info.plist")"
/bin/mkdir -p "$fileel_stage/content/.background" "$fileel_mount"
/usr/bin/ditto "$fileel_app" "$fileel_stage/content/Fileel.app"
/bin/ln -s /Applications "$fileel_stage/content/Applications"
/usr/bin/xcrun swiftc "$fileel_root/Scripts/RenderDMG.swift" "$fileel_root/Fileel/IconArtwork.swift" -o "$fileel_stage/render"
"$fileel_stage/render" "$fileel_stage/artwork" "$fileel_channel" "$fileel_version"
/bin/cp "$fileel_stage/artwork/background.tiff" "$fileel_stage/content/.background/background.tiff"
/bin/mkdir -p "$(/usr/bin/dirname "$fileel_output")"
/usr/bin/hdiutil create -volname "$fileel_volume" -srcfolder "$fileel_stage/content" \
    -format UDRW -fs HFS+ "$fileel_stage/layout.dmg"
/usr/bin/hdiutil attach -readwrite -nobrowse -noautoopen -owners off -mountpoint "$fileel_mount" "$fileel_stage/layout.dmg"
fileel_mounted=true
"$fileel_python" "$fileel_root/Scripts/layout-dmg.py" "$fileel_mount"
if [[ -f "$fileel_app/Contents/Resources/FileelIcon.icns" ]]; then
    /bin/cp "$fileel_app/Contents/Resources/FileelIcon.icns" "$fileel_mount/.VolumeIcon.icns"
    /usr/bin/xcrun SetFile -a C "$fileel_mount"
fi
/usr/bin/hdiutil detach "$fileel_mount"
fileel_mounted=false
/usr/bin/hdiutil convert "$fileel_stage/layout.dmg" -format UDZO -imagekey zlib-level=9 -o "$fileel_output"
/usr/bin/codesign --sign "$fileel_identity" --timestamp "$fileel_output"
/usr/bin/codesign --verify --verbose=2 "$fileel_output"
/usr/bin/hdiutil verify "$fileel_output"
/usr/bin/shasum -a 256 "$fileel_output" > "$fileel_output.sha256"
echo "$fileel_output"
