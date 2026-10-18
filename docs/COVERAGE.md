# v0 coverage and acceptance

The requested v0 includes all functionality described by the Tangerine public demo and website on 2026-10-18, plus the additional tools requested in this chat. Reference: https://tangerineformac.com/

This is a development checklist. The app is not described as feature-complete solely because an operation exists in the catalog

## Implemented engine routes

| Family | Conversion outputs | Tools |
| --- | --- | --- |
| Images | JPG, PNG, WebP, HEIC, TIFF, AVIF, PDF | Compression, metadata, adjustments, text annotation, background, crop, solid redaction, image-to-PDF, collage, resize, rotate/flip, remove background, OCR |
| Audio | MP3, M4A, WAV, FLAC, OGG, Opus, AIFF | Compression, metadata, normalization, trim, mono/stereo, waveform video, bleep, fades, remove silence, join |
| Video | MP4, MOV, MKV, WebM, GIF, MP3 | Compression, metadata, trim, split, crop, speed, mute, snapshots, join, solid redaction, resize, rotate/flip, extract audio, add/extract subtitles |
| PDF | DOCX, PAGES, PPTX, XLSX, JPG, PNG, EPUB, TXT, MD | Compression, metadata, merge, split, reorder/duplicate/remove/rotate pages, password protection, watermark, searchable OCR |
| Documents / EPUB | DOCX, PAGES, PDF, HTML, EPUB, TXT, MD, JPG, PNG | Word count, text comparison, clear formatting |
| Slides | PDF, JPG, PNG | Legacy PPT input |
| Spreadsheets | XLSX, ODS, CSV, TSV, PDF | Legacy XLS input, selected-sheet CSV export with delimiter and encoding |
| Subtitles | SRT, VTT, TXT | Offset, playback speed, join |
| Archives | ZIP, TAR, TAR.GZ | Extraction, listing, integrity test, AES-encrypted ZIP |

The six reference file actions are implemented: AirDrop, floating files, copy, move, copy path, and Terminal. Additional actions: Quick Look, reveal in Finder, batch rename, duplicate, and SHA-256

Input aliases and format families are declared in `Fileel/Catalog.swift`. An exact count of 249 equivalent conversion paths has not been audited. Input format variants, legacy formats, encryption, embedded fonts, and unusual codecs need dedicated fixtures before making that claim

## Fidelity limits that still need work before v0

- The global Finder drag and modifier workflow needs end-to-end interactive validation, especially modifier interactions, cancellation, multiple displays, full-screen apps, and sources other than Finder
- Trackpad haptics are requested through the native API; physical feedback has not been validated by a person on a supported trackpad
- The image editing canvas now implements drag cropping, arrows, rectangles, ellipses, text, numbered callouts, and undo/redo. Exported pixels and coordinate mapping are tested; pointer interactions and the new layout still need interactive QA
- Background editing now implements solid colors, gradients, an image backdrop, spacing, and rounded source corners. Exported pixels are tested; live preview layout still needs interactive QA
- Metadata editing now supports author/artist, title, camera make/model, image lens, signed latitude/longitude, removal of location, and removal of existing tags. Image tags are tested; media edits preserve encoded audio/video stream hashes through remuxing
- Native media previews now implement playback, scrubbing, frame stepping, a waveform decoded from the actual audio, and draggable range handles. Native-unplayable formats still need a proxy-preview path; video crop remains coordinate-based and multiple split/bleep ranges need direct editing
- Image redaction now implements manual solid and blurred regions, plus local face/text detection. Blur is tested not to restore original pixels beneath an earlier solid cover. Tracked video regions, multiple bleep ranges, and exhaustive detection review remain outstanding
- PDF-to-DOCX/PAGES/EPUB exports extracted text with local OCR fallback; original layout, embedded graphics, and table structure are not reconstructed
- PDF-to-PPTX uses rendered pages as slide images; editable elements and preservation of varied page aspect ratios remain outstanding
- PDF-to-XLSX exports text lines as rows, not recovered table cells. Selected-sheet CSV exports cached values, not recalculated formulas or formatting
- Pages output uses installed Apple Pages; its Apple events flow has not been validated interactively. RTFD and Finder text clipping compatibility need fixtures
- Video joining normalizes to 1280×720/30 fps; clips without audio and complex track layouts still need acceptance coverage
- Image compression currently uses encoder quality; exact target-byte or percentage reduction controls remain outstanding
- Engine bundling, exact codec inventory, dependency source/license packaging, release signing, notarization, and an update mechanism remain outstanding

## Acceptance evidence

Automated tests cover generated image conversions, output collision protection, atomic failure behavior, crop/rotation, PDF creation/split/merge/password protection, subtitle timing, archive path checks, cancellation, SHA-256, audio/video encoders and tools, Office/PDF conversions, spreadsheet formats, subtitle tracks, and encrypted ZIP interoperability

Additional tests cover image canvas mapping, annotation output pixels, gradients and rounded backgrounds, camera/GPS metadata preservation and location removal, encoded-stream preservation during media metadata edits, timeline boundaries, waveform decoding, and modifier keys held before a drag

The latest native UI review was blocked because the Mac was locked. The image and media editor changes must not be described as visually accepted until the Mac is unlocked and the actual windows are reviewed

Further acceptance requires real-world fixtures for every supported input extension, visual comparisons for fidelity, accessibility review, light/dark/increased-contrast review, physical trackpad feedback, and a self-contained signed release install on a clean Mac
