# v0 coverage and acceptance

The v0 scope includes local file conversions, contextual editing tools, drag shortcuts, floating files and signed automatic updates, together with the interaction and design requirements tracked below

This is a development checklist. The app is not described as feature-complete solely because an operation exists in the catalog

## Implemented engine routes

| Family | Conversion outputs | Tools |
| --- | --- | --- |
| Images | JPG, PNG, WebP, HEIC, TIFF, AVIF, PDF | Target-size compression, metadata, adjustments, automatic enhancement, annotation, background, crop, solid or randomized-mosaic redaction, image-to-PDF, collage, resize, rotate/flip, remove background, clipboard OCR |
| Audio | MP3, M4A, WAV, FLAC, OGG, Opus, AIFF | Compression, metadata, normalization, trim, mono/stereo, waveform video, bleep, fades, remove silence, join |
| Video | MP4, MOV, MKV, WebM, GIF, MP3 | Target-size compression, metadata, trim, crop, speed, mute, snapshots, join, solid redaction, resize, rotate/flip, extract audio, add/extract subtitles |
| PDF | DOCX, PAGES, PPTX, XLSX, JPG, PNG, EPUB, TXT, MD | Compression, metadata, merge, split, reorder/duplicate/remove/rotate pages, password protection, watermark, searchable OCR |
| Documents / EPUB | DOCX, PAGES, PDF, HTML, EPUB, TXT, MD, JPG, PNG | Word count, text comparison, clear formatting |
| Slides | PDF, JPG, PNG | Legacy PPT input |
| Spreadsheets | XLSX, ODS, CSV, TSV, PDF | Legacy XLS input, selected-sheet CSV export with delimiter and encoding |
| Subtitles | SRT, VTT, TXT | Offset, playback speed, join |
| Archives | ZIP, TAR, TAR.GZ | Extraction, listing, integrity test, AES-encrypted ZIP |

The core file actions are implemented: AirDrop, floating files, copy, move, copy path, and Terminal. Additional actions: Quick Look, reveal in Finder, batch rename, duplicate, and SHA-256

Input aliases and format families are declared in `Fileel/Catalog.swift`. An exact count of 249 equivalent conversion paths has not been audited. Input format variants, legacy formats, encryption, embedded fonts, and unusual codecs need dedicated fixtures before making that claim

## Fidelity limits that still need work before v0

- The global Finder drag and modifier workflow needs end-to-end interactive validation, especially modifier interactions, cancellation, multiple displays, full-screen apps, and sources other than Finder
- Trackpad haptics are requested through the native API; physical feedback has not been validated by a person on a supported trackpad
- The image editing canvas implements a persistent crop frame with move/resize handles, aspect presets, ratio locking, orientation changes, arrows, rectangles, ellipses, text, numbered callouts, and undo/redo. Exported pixels and crop geometry are tested; complete pointer interaction QA remains outstanding
- Background editing now implements solid colors, gradients, an image backdrop, spacing, and rounded source corners. Exported pixels are tested; live preview layout still needs interactive QA
- Metadata editing now supports author/artist, title, camera make/model, image lens, signed latitude/longitude, removal of location, and removal of existing tags. Image tags are tested; media edits preserve encoded audio/video stream hashes through remuxing
- Native media previews implement playback, scrubbing, frame stepping, a waveform decoded from the actual audio, draggable range handles, a shared image/video crop frame and a Space playback shortcut. Unsupported playback formats use an isolated local proxy, with a fast remux attempted first; smaller video proxies retain original pixel coordinates for cropping. Tests decode actual proxy frames/audio and verify cleanup, cancellation and unchanged originals. Multiple bleep ranges still need direct editing
- Image redaction implements manual color fill and randomized mosaic regions, plus local face/text detection. Randomized mosaic is tested to be independent of covered source pixels. Tracked video regions, multiple bleep ranges, and exhaustive detection review remain outstanding
- PDF-to-DOCX and PAGES now use the office engine's positioned-text/graphics importer when each page contains selectable text and its letters survive import. Missing or substituted letters trigger the extracted-text fallback; scanned PDFs retain local OCR. Complex tables, mixed scans and unusual fonts still need broader fixtures; PDF-to-EPUB remains a reflowed text conversion
- PDF-to-PPTX imports editable text and vector shapes. The page-image fallback preserves aspect ratios and centers mixed page orientations rather than stretching them. Generated round-trip fixtures verify page count, portrait geometry, editable text and artwork position
- PDF-to-XLSX recovers rows and columns from text positions and repeated gutters, with one sheet per page. Scans use local OCR plus targeted cell recognition for isolated digits. Tests verify native/scanned tables, numeric values, leading-zero identifiers, genuinely empty cells, inert formula-like text and Office interoperability. Complex merged tables and broader real-world layouts still need acceptance coverage. Selected-sheet CSV exports cached values, not recalculated formulas or formatting
- Pages output uses installed Apple Pages; its Apple events flow has not been validated interactively. Native RTFD input is normalized to rich text with embedded PNG pictures before Office conversion; tests verify Unicode text, bold formatting, repeated attachments, PDF rendering, standalone HTML and embedded EPUB images. Unsupported non-image attachments fail explicitly rather than disappearing. Finder clippings read modern property-list representations and classic text resource forks, with real Apple-compiled fixtures and malformed-map checks
- Markdown with images exports as a portable folder containing the document and relative media paths. Text-only Markdown remains a single file. Tests move a published export after its transaction workspace and original image are gone, compare the extracted PNG bytes and import the Markdown back into DOCX with its picture intact. Image display sizing is omitted to keep standard Markdown syntax rather than raw HTML
- Video joining copies compatible H.264/HEVC streams when Keep Quality is enabled. Mixed clips use the first clip's display canvas, square pixels and the highest selected frame rate; missing audio is padded with silence only when other clips have audio. Tests verify encoded packet preservation, native 1080p dimensions, anamorphic display ratios and the decoded silent/audible timeline. A dedicated sequence sidebar supports selection and reordering before joining. Mixed HDR/SDR and complex track layouts still need acceptance coverage
- Compression accepts a requested percentage for images, PDFs and video. Image/PDF previews measure actual local test encodes; video shows a bitrate-based estimate. Exact byte targets are not guaranteed, and an unreachable target is reported honestly. An original-file fallback is allowed only when no metadata change was requested; privacy changes take precedence over avoiding a larger output
- Generated privacy fixtures cover JPEG orientation and exact decoded pixels after lossless metadata removal, PNG pixels, unchanged video packets, global/stream tags, and PDF Info/XMP removal at 0% reduction with selectable text, form values, annotations and bookmark destinations preserved. Source bytes remain unchanged
- PDF organization now uses per-page thumbnail identities, reorder, duplicate, delete and individual rotation. Backend tests verify page order, selectable text, independent duplicate rotation and preservation of originals; drag-and-drop UI acceptance remains outstanding
- Watermark preview and export use the same vector PDF renderer. Tests verify all four page rotations, artwork placement, selectable source/watermark text, chosen metadata and cancellation
- Raster PDF export and OCR share that explicit page transform, preserving all four rotations across macOS versions; invalid or excessive raster resolutions fail before bitmap allocation
- The complete runtime-bearing Developer ID app and its branded DMG have passed Apple notarization, ticket validation and update-signature verification. An isolated signed app has completed real Sparkle installation/relaunch, invalid-download rejection, preference retention and a stable/beta/stable round trip, including background checks. Two protected beta CI runs repeated signing, notarization, branded DMG creation, installed-update tests and temporary draft upload/download/cleanup ([first](https://github.com/thiagonarcizo/Fileel/actions/runs/39107534104), [second](https://github.com/thiagonarcizo/Fileel/actions/runs/39111478463)). This integrated candidate still needs that rehearsal; production-channel and visual updater acceptance remain outstanding
- The runtime payload contains pinned ARM64 conversion tools, codec dependencies, upstream notices and a corresponding source archive. Its 223 native executables/libraries declare macOS 14 or earlier. All 82 integrated native tests passed with Homebrew, `/usr/local`, the system LibreOffice installation and build-only runtime dependencies denied to the test process. A separate clean-Mac installation and complete signed-app acceptance remain outstanding
- Collage previews include every selected source and share gradient/rounded-corner rendering with exports. Full image decoding no longer silently shrinks originals wider than 16384 pixels

## Acceptance evidence

Automated tests cover generated image conversions, output collision protection, atomic failure behavior, crop/rotation, PDF creation/split/merge/password protection, subtitle timing, archive path checks, cancellation, SHA-256, audio/video encoders and tools, Office/PDF conversions, spreadsheet formats, subtitle tracks, and encrypted ZIP interoperability

Additional tests cover image canvas mapping, annotation output pixels, gradients and rounded backgrounds, camera/GPS metadata preservation and location removal, encoded-stream preservation during media metadata edits, timeline boundaries, waveform decoding, and modifier keys held before a drag

Native UI review verified the onboarding, Test Haptic label, Keep Quality enabled by default, conditional quality slider, and double-click slider reset. Switching the preview's modifier changes modes without hovering a slice. A wheel screenshot exposed truncated captions; compact labels and font measurements now cover every catalog group, and the updated rendering still needs review. Dedicated photo, video and PDF windows are not yet fully accepted

Further acceptance requires real-world fixtures for every supported input extension, visual comparisons for fidelity, accessibility review, light/dark/increased-contrast review, physical trackpad feedback, and a self-contained signed release install on a clean Mac
