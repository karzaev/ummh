# Changelog

## Unreleased

- Backport FluidAudio's v3 joint output backings and compiled-model cache validation while retaining the pinned SDK revision. Repair incomplete caches before loading and replace managed files with a mismatched published size.
- Apply and verify the dependency patch through the local build and test scripts. Add regression coverage for damaged caches, offline startup, file recovery and unchanged joint predictions.
- Document isolated FluidAudio decoder and model-cache evaluations.
- Validation: 52 regression tests passed and 128 paired recognition comparisons produced identical transcripts. Cache checks reproduced three Core ML crashes and verified five successful file repairs.
- Local integration passed 63 tests and 24 streaming replays through the signed app with identical baseline transcripts. Dependency preparation was checked from a clean checkout, on repeat runs and with an unrelated edit that it preserved and rejected.

## 0.1.2

- Open the recording panel on the display under the cursor and keep it there until the panel closes. If that display disconnects, move the panel to an available display.
- Prevent idle display sleep while starting and recording, releasing the assertion when capture stops or fails.
- Create the menu once and update its status and icon only when their displayed values change.
- Adapt VoiceInk's input-only AUHAL capture, hardware-format setup and bounded callback queue, keeping audio in memory and draining queued PCM on stop.
- Resolve the preferred microphone with VoiceInk-style fallback, excluding the internal microphone when the lid is closed and retaining external headset support.
- Isolate microphone capture from system output changes and validate the active input before previews and final delivery.
- Verified with 52 automated tests and a signed local Release build. Checks cover input selection, 44.1/48 kHz conversion, stereo downmix, capture errors, cancellation and final PCM draining. Live dictation passed with the system-default and USB display microphones, each with the MacBook lid open and closed.
- Packaged one arm64 DMG for macOS 26+, with verified ad-hoc signing, minimum OS version, SHA-256 and a scan for private build paths and signing details.

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
