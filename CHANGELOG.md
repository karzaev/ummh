# Changelog

## Unreleased

- Open the recording panel on the display under the cursor and keep it there until the panel closes. If that display disconnects, move the panel to an available display.
- Prevent idle display sleep while starting and recording, releasing the assertion when capture stops or fails.
- Create the menu once and update its status and icon only when their displayed values change.
- Keep native routing for the system-default microphone and configure the tap from the hardware input format, avoiding a startup regression when input and output sample rates differ. Recover unchanged audio inputs after output configuration changes, and report actual input or format loss separately.
- Explain that closed-lid MacBooks require an external microphone.
- Verified with 53 automated tests, including a stale client sample-rate regression, a signed local Release build and a macOS display-sleep assertion acquire/release check. USB audio recovery still requires a live hardware check.

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
