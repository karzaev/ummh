# Changelog

## 0.1.1

- One Apple Silicon build for macOS 26 and later.
- Compatible microphone selection on macOS 26, retaining scoped AudioUnit access on macOS 27.
- Exclude the unused optional NeMo text-processing library from dictation builds.
- Verified with 38 automated tests covering recording lifecycle, streaming, cancellation and delivery.

## 0.1.0

- Native macOS dictation with local Parakeet TDT v3 recognition.
- Russian, English and automatic language detection.
- Hold-to-record shortcut, Escape cancellation, clipboard output and optional automatic paste.
- Compact waveform panel, optional live text and recording feedback sounds.
- Streaming previews with per-word agreement and guarded session cancellation.
- Public documentation and an ad-hoc-signed, unnotarized Apple Silicon DMG.
- Regression coverage for recording lifecycle, cancellation, word agreement, shortcuts and paste guards.
