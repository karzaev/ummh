# Architecture

ummh is a SwiftPM executable packaged as a native macOS app. SwiftUI provides
settings and recording views; AppKit owns the menu bar, nonactivating recording
panel and application lifecycle. The deployment target is macOS 26 on Apple Silicon.

## Recognition

AudioCapture converts microphone PCM into mono Float32 samples at 16 kHz.
Audio stays in memory. Explicit microphone selection uses scoped AudioUnit access
on macOS 27 and the compatible AudioUnit property on macOS 26, before capture starts.
SpeechEngine owns a warm Parakeet TDT v3 recognizer and
Silero VAD through FluidAudio. Streaming previews process unconfirmed audio at
one-second intervals. WordAgreementEngine tracks each word's confirmation
history and punctuation boundaries; the final pass combines a stable prefix
with the remaining tail when appropriate. FluidAudio's optional NeMo text-processing
trait is disabled; this dictation pipeline does not use TTS or inverse text normalization.

## Sessions

SessionController owns one operation task with structured preview and release
handling. Cancellation stops capture immediately and drains pending recognition
before allowing another session. Cancelled work cannot deliver text, and stale
paste or status callbacks cannot change a newer session.

A nonempty final result is copied once. Optional paste checks Accessibility,
the foreground app, released shortcut modifiers and the clipboard version
before posting Command+V. Synthetic paste events are ignored by the shortcut
monitor. The recording panel never takes keyboard focus.

## Permissions and distribution

Microphone permits capture. Accessibility permits the global event tap and
optional paste. Input Monitoring is not requested. Permission checks run on
launch, activation and before recording; the app does not modify privacy data.

Local builds use an Apple Development identity. Distribution packaging operates
on a copy and uses an ad-hoc signature. See [releases](releases.md) for packaging
and [testing](testing.md) for validation procedures.
