# Third-party components

No Tangerine code, binaries, artwork, icons, fonts, sounds, or extracted resources are included

Fileel invokes locally installed engines as separate processes. The current repository does not redistribute those engines

| Component | Purpose | Upstream licensing reference |
| --- | --- | --- |
| FFmpeg / FFprobe | Media encoding, filters, probing | https://ffmpeg.org/legal.html — LGPL or GPL depending on build configuration |
| Pandoc | Document interchange | https://github.com/jgm/pandoc/blob/main/COPYRIGHT — GPL |
| LibreOffice | Office rendering and conversion | https://www.libreoffice.org/about-us/licenses/ — MPL and component-specific terms |
| 7-Zip | AES-encrypted ZIP and archive integrity | https://www.7-zip.org/license.txt — LGPL, BSD, and restrictions on unRAR components |
| Apple frameworks / SF Symbols | Native platform functionality and interface symbols | Apple platform SDK and SF Symbols terms |

Before distributing a bundled engine, record its exact version, build flags, included libraries, license texts, and corresponding source obligations. Do not assume the Homebrew FFmpeg build has the same license as an upstream minimal build

The application icon and folded-ribbon mark are original vector geometry. System fonts are referenced through native APIs and are not redistributed
