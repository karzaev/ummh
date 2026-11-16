# Testing

Run the automated suite with:

```sh
swift test
```

Tests cover session startup, recording, streaming previews, release, cancellation,
stale recognition results, clipboard delivery, paste guards and shortcut handling.
They also cover display-sleep assertion lifetime, VoiceInk-style input selection,
closed-lid fallback, loss of input before release and headset identification.
The capture queue is exercised with deterministic 44.1/48 kHz PCM, stereo downmix,
converter flush, oversized callbacks and render failures.
They use isolated settings and fake I/O; they do not record the microphone,
download models or post keyboard events.

For manual testing, use the packaged app and verify recording, release-to-copy,
optional paste, Escape cancellation and another recording after cancellation.
Microphone and Accessibility access are required. Check both the system-default
microphone and an explicitly selected input on macOS 26 and macOS 27 or later.
Check the packaged executable's minimum OS with `vtool -show-build`, alongside
`LSMinimumSystemVersion` in its Info.plist. Compilation for macOS 26 does not
replace a live recording and recognition check on that OS.

Verify these four combinations using the packaged app and the same short phrase.
Check that the waveform reacts, streaming continues and the final text is copied
or pasted after release.

| Input setting | Lid open | Lid closed |
| --- | --- | --- |
| System default | Uses the available default input | Skips the hardware-disabled internal microphone and selects an available external input |
| Explicit USB display microphone | Uses the selected microphone | Uses the selected microphone |

Close the lid before starting each closed-lid recording. If no external input is
available, expect a clear error rather than a successful silent recording. Check
Escape followed by another recording with both input settings. Change only the
audio output during recording and check that capture continues. Unplug the active
input and check cancellation without pasted text, then reconnect and start again.
Include different input and output sample rates, such as 44.1 kHz and 48 kHz.
The system input/output settings must remain unchanged after these checks.

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
