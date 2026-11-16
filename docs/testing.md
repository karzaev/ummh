# Testing

Run the automated suite with:

```sh
swift test
```

Tests cover session startup, recording, streaming previews, release, cancellation,
stale recognition results, clipboard delivery, paste guards and shortcut handling.
They also cover display-sleep assertion lifetime, unchanged-input notifications,
engine restart decisions, input/format loss and built-in versus external inputs
with the lid closed.
They use isolated settings and fake I/O; they do not record the microphone,
download models or post keyboard events.

For manual testing, use the packaged app and verify recording, release-to-copy,
optional paste, Escape cancellation and another recording after cancellation.
Microphone and Accessibility access are required. Check both the system-default
microphone and an explicitly selected input on macOS 26 and macOS 27 or later.
Check the packaged executable's minimum OS with `vtool -show-build`, alongside
`LSMinimumSystemVersion` in its Info.plist. Compilation for macOS 26 does not
replace a live recording and recognition check on that OS.

For a MacBook with its lid closed, select an external microphone in Settings.
Apple silicon MacBooks disconnect the built-in microphone in this position.
Verify a USB display or headset input with the lid open and closed, both explicitly
selected and as the system default. Change only the audio output during recording
and check that input capture continues. Unplug the selected input and check for
cancellation with no pasted text, then reconnect and start another recording.

During a long recording, check `pmset -g assertions` for the `ummh recording`
display-sleep assertion. It must disappear after release, Escape, a capture error
or app termination. During streaming, the menu and menu-bar image should remain
stable while the waveform and live text update.

With two displays and a microphone that stays connected, start dictation with
the cursor on the secondary display. Move the cursor to the other display and
check that the panel stays in place. Disconnect the panel's display during
recording and check that the panel moves to the remaining display and the
transcript is delivered on release. Start another recording with the cursor on
the desired display to verify that the selection resets when the panel closes.

File replay is available for recognition diagnostics:

```sh
dist/ummh.app/Contents/MacOS/ummh --replay /path/to/sample.wav
dist/ummh.app/Contents/MacOS/ummh --replay /path/to/sample.wav --batch
```

Replay writes the supplied recording's transcript to standard output. It does not
record audio or change the clipboard. Replay timings measure computation rather
than live microphone latency.
