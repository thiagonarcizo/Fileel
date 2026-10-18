# Distribution

Fileel targets Apple Silicon and macOS 14 or newer. GitHub Releases is the intended download channel. A signed development preview is not evidence that every conversion or a clean installation has passed acceptance

## Signing

Use an Apple Developer Program team with permission to distribute Mac apps. A local Developer ID Application certificate needs its private key in the signing Mac's keychain. Keep that key in the keychain; never commit certificates, private keys, credentials, or exported signing archives to this repository

Create a Release archive using the team's normal automatic development signing:

```sh
xcodebuild archive -project Fileel.xcodeproj -scheme Fileel \
  -configuration Release -destination 'generic/platform=macOS' \
  -archivePath build/distribution/Fileel.xcarchive \
  -derivedDataPath build/distribution/DerivedData
```

Open the archive in Xcode Organizer. Choose **Distribute App → Direct Distribution → Distribute**. Xcode signs with Developer ID and uploads the app to Apple's notary service using the connected Apple Account. Upload completion means processing has started; wait for **Accepted**, then choose **Export Notarized App**

This flow uses the existing Xcode session and does not require storing an app-specific password in a script. If Apple requires authentication or an agreement, complete that step in Apple's own interface

## DMG

Run the packaging script with the app exported after notarization:

```sh
bash Scripts/create-dmg.sh \
  build/distribution/notarized/Fileel.app \
  build/distribution/Fileel-0.0.1-arm64.dmg
```

If multiple Developer ID identities are available, set `FILEEL_SIGNING_IDENTITY` to the intended certificate's full name. The script verifies the app's signature, stapled ticket, and Gatekeeper assessment, preserves the app bundle, creates an Applications shortcut, signs the DMG, verifies its structure, and writes a SHA-256 checksum

The notarization ticket is attached to the enclosed app. The script does not submit the DMG itself for a separate notarization. Validate an internet-downloaded copy on a separate Mac before declaring a public release ready

## Remaining release requirements

External conversion engines are currently discovered locally and are not bundled. A DMG containing Fileel alone therefore does not provide every conversion on a clean Mac. Complete dependency packaging with exact versions, license notices and applicable source obligations, or clearly label a preview with its external requirements

Check [coverage](COVERAGE.md), native drag behavior, onboarding, file permissions, and the installed app before publishing. Keep signing and notarization logs outside the public repository

Apple references: [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/), [notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
