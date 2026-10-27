# ummh

A small, native dictation app for macOS.

Dictation apps keep getting more features. I wanted Russian support and local
speech recognition. No cloud processing. No LLM with editorial ambitions.

## Use

Hold **Right Command**, speak, release. The text goes to your clipboard.
Enable **Paste automatically** to insert it into the active app. **Escape** cancels.

A small waveform panel shows recording and processing. Live transcription is
optional. You can change the shortcut, microphone and language in Settings:
Russian, English or automatic detection.

Recognition runs on your Mac with Parakeet TDT v3 through FluidAudio. ummh
doesn't upload audio or transcripts. Models need an initial download.
No saved recordings or transcript history.

On first launch, allow **Microphone** and **Accessibility** access, download the
model if prompted, and wait for **Ready to dictate**.

## Install

**Apple Silicon · macOS 27+**

[Download v0.1.0 (DMG)](https://github.com/karzaev/ummh/releases/download/v0.1.0/ummh-0.1.0-arm64-adhoc.dmg),
open it, and drag ummh into Applications. This build is not notarized; macOS may
require approval on first launch. See [release details](docs/releases.md).

To build from source, you need Xcode 27, Swift 6.2+ and an Apple Development
signing identity:

```sh
git clone https://github.com/karzaev/ummh.git
cd ummh
swift test
./scripts/build-local.sh
open dist/ummh.app
```

## Credits

Built with Swift, SwiftUI, AppKit and
[FluidAudio](https://github.com/FluidInference/FluidAudio).
Parts of the streaming recognition, recording UI and sounds come from
[VoiceInk](https://github.com/Beingpax/VoiceInk).

[GPL v3](LICENSE) · [Attribution](NOTICE.md) ·
[Architecture](docs/architecture.md) · [Testing](docs/testing.md)

by [karzaev](https://karzaev.xyz)
