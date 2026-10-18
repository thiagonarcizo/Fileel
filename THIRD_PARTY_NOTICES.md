# Third-party components

Fileel invokes conversion engines as separate processes. Release builds package the versions recorded in [the runtime lock](Distribution/runtime-lock.json). Their source archive is distributed alongside the app, with the build recipe described in [runtime distribution](docs/RUNTIME-DISTRIBUTION.md).

| Component | Purpose | License |
| --- | --- | --- |
| FFmpeg / FFprobe | Media encoding, filters and probing | LGPL 2.1 or later for Fileel's build configuration |
| LAME | MP3 encoding | LGPL 2.0 or later |
| libogg / libvorbis / Opus / libvpx / WebP | Audio and video codecs | BSD licenses and upstream notices |
| libaom | AV1 encoding | BSD 2-Clause and upstream patent grants |
| Pandoc | Document interchange | GPL 2.0 or later |
| LibreOffice | Office rendering and conversion | MPL 2.0 and component-specific terms |
| 7-Zip | Archives, encryption and integrity | LGPL, BSD and the unRAR restriction |
| Ghostscript | PDF compression | AGPL 3.0 or later |
| Sparkle | Signed app updates | MIT and component notices inside Sparkle.framework |

Bundled license texts are in `Fileel.app/Contents/Resources/Engines/Notices`. LibreOffice also retains its original `LICENSE`, `LICENSE.html` and `NOTICE` files inside its own app bundle. The runtime source archive includes the exact pinned upstream sources and Fileel's build recipe; Fileel applies no source patches to these tools.

Native functionality uses Apple's platform frameworks and SF Symbols under the applicable SDK terms. System fonts are referenced through native APIs and are not redistributed. The application icon and folded-ribbon mark are original vector geometry.

Build-only DMG metadata tools, `ds_store` and `mac_alias`, are MIT licensed and pinned by version and checksum. They are not shipped as app dependencies.
