# Releases

ummh supports Apple Silicon and macOS 27 or later.

Open the DMG and drag ummh into Applications. The build is ad-hoc signed and is
not notarized by Apple. macOS may require explicit first-launch approval; see
[Apple's guidance](https://support.apple.com/en-gb/102445).

Models download on first use and are not included in the DMG. Microphone and
Accessibility access are requested by the app.

## Packaging

```sh
./scripts/build-local.sh
./scripts/package-preview.sh
```

The packaging script copies the local app, strips debug symbols, replaces the
copy's signing identity with an ad-hoc signature and creates a DMG plus SHA-256.
It does not change the local app, its signature or existing permissions.

Publish the DMG and checksum with a source tag matching the application build.
Keep LICENSE, NOTICE.md and dependency source references available with the release.
Homebrew Cask is not currently provided.
