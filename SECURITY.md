# Security

Report vulnerabilities through [private vulnerability reporting](https://github.com/thiagonarcizo/Fileel/security/advisories/new). Please do not include private files, credentials or exploitable details in public issues

Fileel processes files locally. Updates must pass both Apple Developer ID verification and Sparkle's Ed25519 verification. The update feed itself also requires a valid signature. A release is announced to installed apps only after notarization and downloadable-asset verification succeed

Changes to `main` and `dev` require a pull request. Only the owner and repository administrators may merge. Maintainers review contributions, resolve discussions and wait for the required build, test and security checks. Administrators use GitHub's recorded pull-request exception for their own changes, because GitHub does not allow self-approval

Forked pull requests receive no signing credentials. Workflows use read-only tokens by default, pinned official actions and disposable GitHub-hosted runners. Signing credentials belong only to the `production` and `beta` environments, each restricted to its corresponding branch

Release automation stays locked until clean-install and installed-app update acceptance have passed. Credentials, notarization logs and signing archives must never be committed or uploaded as workflow artifacts
