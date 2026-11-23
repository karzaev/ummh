# Architecture

ummh is a SwiftPM executable packaged as a native macOS app. SwiftUI provides
settings and recording views; AppKit owns the menu bar, nonactivating recording
panel and application lifecycle. The deployment target is macOS 26 on Apple Silicon.

## Recognition

AudioCapture adapts VoiceInk's input-only AUHAL capture. Each recording enables
input bus 1, disables output bus 0, selects a resolved input device and reads
its hardware format before configuring a Float32 client format at the same rate.
Changing the system audio output does not reconfigure this input-only unit.
The audio callback renders into a bounded, preallocated queue. A serial processing
queue downmixes and resamples audio through AVAudioConverter to mono Float32 at
16 kHz. Stop waits for render callbacks and drains the queued audio and converter
before returning the complete in-memory PCM. Capture errors prevent delivery.

Device resolution follows VoiceInk. Prefer the system-default or explicitly
selected input, then an available fallback. With the lid closed, skip the internal
MacBook microphone and use an available external input. An external headset on
the built-in codec is identified separately. The chosen input is retained for the
session. Its availability, lid restriction and hardware format are checked during
startup, before previews and on release. Losing that input cancels the recording;
a subsequent recording resolves the available devices again.

SpeechEngine owns a warm Parakeet TDT v3 recognizer and
Silero VAD through FluidAudio. Streaming previews process unconfirmed audio at
one-second intervals. WordAgreementEngine tracks each word's confirmation
history and punctuation boundaries; the final pass combines a stable prefix
with the remaining tail when appropriate. FluidAudio's optional NeMo text-processing
trait is disabled; this dictation pipeline does not use TTS or inverse text normalization.

FluidAudio stays at the revision in Package.swift, with the reviewed changes in
`patches/fluidaudio.patch`. The build and test scripts apply that exact patch and
reject a different revision or unrelated checkout changes. The patch preallocates
the v3 joint's top-K outputs and validates compiled model programs and referenced
weights before loading. Incomplete caches are repaired before Core ML is called;
offline startup reports an error and preserves the cache. File downloads replace
managed files whose published size differs. Equal-size content corruption is not
detected. These checks run during model preparation, outside the recording loop.

## Sessions

SessionController owns one operation task with structured preview and release
handling. Cancellation stops capture immediately and drains pending recognition
before allowing another session. Cancelled work cannot deliver text, and stale
paste or status callbacks cannot change a newer session.
A display-sleep assertion starts before microphone setup and is released when
capture stops, including startup failures and cancellation. It is released before
final recognition and paste. The assertion prevents idle display sleep during
recording; the normal explicit sleep notification still cancels the session.

A nonempty final result is copied once. Optional paste checks Accessibility,
the foreground app, released shortcut modifiers and the clipboard version
before posting Command+V. Synthetic paste events are ignored by the shortcut
monitor. The recording panel never takes keyboard focus.
It opens on the display under the cursor and keeps that display until it closes.
If the display disappears, the panel selects an available display when macOS
reports the change. The recording session continues if its microphone remains available.
The menu is created once. Status text and the menu-bar image are updated only
when their displayed values change; streaming text continues to refresh the panel.

## Permissions and distribution

Microphone permits capture. Accessibility permits the global event tap and
optional paste. Input Monitoring is not requested. Permission checks run on
launch, activation and before recording; the app does not modify privacy data.

Local builds use an Apple Development identity. Distribution packaging operates
on a copy and uses an ad-hoc signature. See [releases](releases.md) for packaging
and [testing](testing.md) for validation procedures.
