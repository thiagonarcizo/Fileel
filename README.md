# Fileel

Native file conversion and tools for Apple Silicon Macs, built with SwiftUI and AppKit

**Status: development build, not a published v0 release**

Drag files in Finder, press **Shift** for conversions, **Command** for tools, or **Control** for actions, then drop on an option. Release the modifier to keep the menu open; drop in the center or press Escape to cancel. The main window provides an alternative using standard controls

## Build

Requires Xcode 16 or newer and macOS 14 or newer. The app target is restricted to `arm64`

```sh
xcodebuild build -project Fileel.xcodeproj -scheme Fileel \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO
```

The output is `build/Build/Products/Debug/Fileel.app`

## Local engines

Native image and PDF operations use ImageIO, Core Image, PDFKit, and Vision. Additional operations discover these local executables:

```sh
brew install ffmpeg pandoc sevenzip
brew install --cask libreoffice
```

Pages export also requires Apple Pages and the system's automation permission, requested only when creating a Pages document

Search order: `Fileel.app/Contents/Resources/Engines`, a `FILEEL_<ENGINE>` environment override, the standard application location for LibreOffice, Homebrew, and `/usr/bin`. Engines are **not bundled yet**; installing this development app alone does not install its conversion dependencies

## Features and verification

See [the coverage checklist](docs/COVERAGE.md) for the implementation scope and fidelity limits. A catalog entry is not evidence that a conversion has been validated on every input variation

```sh
swift test
```

The tests generate their own files in temporary folders. Backend integration tests skip when the corresponding engine is unavailable

## Design

The folded-ribbon identity is original. Fileel lives in the menu bar and does not show a Dock icon. Its layered Icon Composer asset supports the system's icon appearances; the menu bar uses a template symbol. Interface text uses the macOS system font; the welcome heading uses the system serif design. Interactive accents inherit the current macOS accent color. The app does not declare a fixed accent color or force an appearance

Haptics are enabled by default and require a compatible trackpad. Selection sounds are disabled by default. Both can be changed independently in Settings

## Distribution

The intended distribution channel is GitHub Releases. This repository contains development packaging instructions, not a published release. A release requires dependency and license packaging, Developer ID signing, notarization, and completion of the acceptance checklist

The signing and DMG workflow is documented in [distribution](docs/DISTRIBUTION.md). The packaging script requires an already notarized app and refuses to overwrite an existing disk image

Fileel is an independent implementation inspired by a file utility workflow. It does not include Tangerine's code, branding, assets, sounds, or implementation details

## License

Fileel's own source is licensed under MIT. Third-party engines have separate licenses; see [third-party notices](THIRD_PARTY_NOTICES.md)

Regenerate icon assets from their shared drawing source:

```sh
swiftc Fileel/IconArtwork.swift Scripts/RenderIcon.swift -o /tmp/fileel-render-icon
/tmp/fileel-render-icon Fileel/Assets.xcassets/AppIcon.appiconset docs/brand
```
