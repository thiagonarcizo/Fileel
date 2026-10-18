# Fileel conversion runtimes

Fileel invokes these tools as separate processes. Its native interface does not link against their libraries. The source code of Fileel is covered by its MIT license; each bundled tool retains its own license.

`Distribution/runtime-lock.json` records the exact upstream versions, download checksums, source locations and licenses. The release includes a **Fileel-Runtime-Sources.tar** download with these upstream sources and the build recipe. License texts are also available inside Fileel at `Contents/Resources/Engines/Notices`; LibreOffice retains its original license and notice files in its own bundle.

## Rebuilding

On an Apple silicon Mac, install Xcode and the build-only tools `cmake`, `ninja` and `pkgconf`, then run:

```sh
python3 Scripts/build-runtimes.py
```

The build uses `MACOSX_DEPLOYMENT_TARGET=14.0`, static codec libraries and Apple system frameworks. It disables FFmpeg's GPL and nonfree options, network support, capture devices and output devices. The synthetic `lavfi` input remains enabled for waveform visualizations and reproducible test fixtures. FFmpeg reports LGPL 2.1 or later for this configuration.

FFmpeg includes the encoders needed by Fileel: LAME MP3, Opus, Vorbis, VP9, WebP and AV1, plus native VideoToolbox H.264/HEVC. Ghostscript and 7-Zip are built from their pinned source releases. Pandoc uses an upstream ARM64 build whose declared minimum is macOS 14; newer upstream binaries currently require newer operating systems. LibreOffice uses the original ARM64 distribution with its existing signature and notices intact.

The recipe rejects standalone binaries that require a newer macOS release or refer to Homebrew libraries. Builds take place before signing credentials enter the job. No local application profiles, documents, credentials or user preferences are copied into the payload.

## Layout and replacement

The payload's `MacOS` directory contains standalone executables. `Helpers/LibreOffice.app` contains the office runtime, and `Resources` contains notices, the engine manifest and Ghostscript data. Fileel locates these bundled copies relative to its own bundle, so moving the app does not change their location.

To use a modified tool, rebuild the source package and replace the corresponding executable in a development copy of Fileel before signing it. Developer builds can also use explicit `FILEEL_FFMPEG`, `FILEEL_FFPROBE`, `FILEEL_PANDOC`, `FILEEL_7ZZ`, `FILEEL_GS` and `FILEEL_SOFFICE` paths when no bundled copy exists. Source archives retain upstream build files and licenses. Fileel applies no source patches to these runtimes; its build flags are recorded in the included recipe.

The release pipeline signs the standalone executables and the parent Fileel app after embedding the payload. It verifies the original LibreOffice bundle before notarization. Final acceptance also requires conversion tests using the packaged copies, without Homebrew on the runtime search path, and a successful Apple notarization of the complete app.
