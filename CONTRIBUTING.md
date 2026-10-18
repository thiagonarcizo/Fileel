# Contributing to Fileel

Open an issue to discuss a feature or submit a focused pull request. Include screenshots for interface changes and describe the behavior you verified

Use Xcode 27 on Apple Silicon. For local engine tests, install `ffmpeg`, `pandoc`, `sevenzip`, `ghostscript` and LibreOffice, then run `swift test`. Build the app with the shared Fileel scheme

Write code comments in English, in lower case except acronyms, without a final period. Keep comments short and explain the reason for a decision

Contributions target `dev`; reviewed releases graduate to `main`. Both branches require passing checks and maintainer review. Contributors cannot push to them or merge their own pull requests. Release credentials are never available to pull-request workflows

Keep original files unchanged, make cancellation safe and test exported results. Do not upload personal sample files or credentials. See [SECURITY.md](SECURITY.md) for private vulnerability reports
