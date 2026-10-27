# Testing

Run the automated suite with:

```sh
swift test
```

Tests cover session startup, recording, streaming previews, release, cancellation,
stale recognition results, clipboard delivery, paste guards and shortcut handling.
They use isolated settings and fake I/O; they do not record the microphone,
download models or post keyboard events.

For manual testing, use the packaged app and verify recording, release-to-copy,
optional paste, Escape cancellation and another recording after cancellation.
Microphone and Accessibility access are required.

File replay is available for recognition diagnostics:

```sh
dist/ummh.app/Contents/MacOS/ummh --replay /path/to/sample.wav
dist/ummh.app/Contents/MacOS/ummh --replay /path/to/sample.wav --batch
```

Replay writes the supplied recording's transcript to standard output. It does not
record audio or change the clipboard. Replay timings measure computation rather
than live microphone latency.
