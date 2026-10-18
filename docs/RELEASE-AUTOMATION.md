# Automated releases

The `Release` workflow runs after every push or merged pull request to `main` or `dev`. Production and beta use one bundle identity and preference store, distinct DMG names and separate update feeds

| Source | Environment | Download | App update feed |
| --- | --- | --- | --- |
| `main` | `production` | Stable GitHub release | `updates/stable/appcast.xml` |
| `dev` | `beta` | GitHub prerelease | `updates/beta/appcast.xml` |

## Publication sequence

1. Run the native build, engine tests, release-tool tests, secret scan and Swift CodeQL analysis
2. Check the environment's first-release acceptance gate
   Build the pinned runtime payload and its corresponding source archive before importing signing secrets, test conversions with that payload, and verify that usage did not change the office runtime's signature
3. Import the expected Developer ID certificate into an ephemeral runner keychain
4. Archive the exact source commit with a build number shared across both channels, then sign Sparkle's nested helpers, framework and enclosing app from the inside out
5. Require bundled conversion engines and the expected Sparkle public key
6. Submit the app to Apple, require `Accepted`, staple and validate its ticket
7. Create and sign the DMG, notarize it, staple it and verify its structure
8. Sign the final DMG with Sparkle's Ed25519 key and verify against the public key shipped in Fileel
9. Upload a draft release, download its DMG again and verify its hash and signature
10. Sign the feed itself, publish the release, then advance only that channel's feed with an atomic fast-forward commit to `updates`

The bot never pushes to `main` or `dev`. The publication branch contains feed data only and does not trigger builds. Beta releases never replace GitHub's latest stable download. Runs are serialized across both channels; a superseded source commit or older build cannot advance the feed

## Credentials

Configure these as **environment secrets** in both `production` and `beta`. Do not store them as repository files, artifacts, workflow literals or pull-request-accessible credentials

| Secret | Contents |
| --- | --- |
| `FILEEL_CERTIFICATE_P12` | Base64 of the Developer ID Application certificate with its private key |
| `FILEEL_CERTIFICATE_PASSWORD` | Password protecting that PKCS#12 export |
| `ASC_KEY_ID` | Existing App Store Connect team key's identifier |
| `ASC_ISSUER_ID` | That team's issuer identifier |
| `ASC_PRIVATE_KEY` | Base64 of the existing `.p8` file, matching the Balanço configuration |
| `FILEEL_SPARKLE_PRIVATE_KEY` | Sparkle's private-key export string, without another base64 layer |

The signing certificate must belong to team `TQ87ZCU6H5`. Validate the API key's team and notarization permissions before configuring CI. GitHub does not let administrators download existing secret values from another repository; use their original local credentials

The runner deletes the temporary keychain and key files even when signing or notarization fails. Public assets are the DMG, corresponding runtime sources, their SHA-256 checksums and release metadata. No private key, signing export or local user data is uploaded. No personal access token or self-hosted runner is required

## First-release gate

Each environment has `FILEEL_RELEASE_READY=false` until the actual installed-app update test and clean-Mac acceptance pass. Missing credentials, engines, signatures or Apple acceptance fail publication. Enable the variable only after those checks have succeeded; setting it is not a substitute for running them

A manual `Release` run defaults to verification only. On the reviewed `main` or `dev` branch, it builds, signs and notarizes the complete app and DMG using that branch's protected environment. It uploads a temporary private draft, downloads every asset to verify hashes and the update signature, then removes only that run's uniquely named draft/tag. It never changes either appcast. This can validate credentials and delivery before enabling the public-release gate; it does not replace an installed-app update test. Set the manual `publish_update` input only when a public release is intended and its gate is already enabled

The owner reviews and merges a pull request to release it. Environment branch restrictions allow `production` only from `main`, and `beta` only from `dev`. This avoids requiring a second manual deployment approval after an already-authorized merge

## Installed apps

Automatic checks run approximately hourly while Fileel is running. Sparkle presents the update through the app's native update UI; publishing a release does not forcibly interrupt editing or guarantee an immediate notification. Users can check manually at any time

Switching to beta selects its feed. Switching back selects stable immediately and keeps the currently installed version until a newer stable build exists. Sparkle prevents downgrades; Fileel preserves the same bundle identity and settings across channels, and About continues to identify the actual installed beta until a stable update is installed

Before the first public download, test an older installed release updating to a newer one, invalid-signature rejection, preferences, launch behavior and both channel transitions. Validate the actual public feed and downloaded release, rather than assuming a successful build proves update installation
