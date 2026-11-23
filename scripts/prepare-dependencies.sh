#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift package resolve
CHECKOUT="$PWD/.build/checkouts/FluidAudio"
PATCH="$PWD/patches/fluidaudio.patch"
REVISION=762baf6733ca0f0dbeb1ce335363fc75066bd2c9
if [[ "$(git -C "$CHECKOUT" rev-parse HEAD)" != "$REVISION" ]]; then
    printf 'Unexpected FluidAudio revision; review the local patch before building.\n' >&2
    exit 1
fi
if [[ -n "$(git -C "$CHECKOUT" ls-files --others --exclude-standard)" ]] || ! git -C "$CHECKOUT" diff --cached --quiet; then
    printf 'FluidAudio checkout contains unrelated changes; leaving it untouched.\n' >&2
    exit 1
fi
if git -C "$CHECKOUT" diff --quiet; then
    git -C "$CHECKOUT" apply --check "$PATCH"
    git -C "$CHECKOUT" apply "$PATCH"
fi
if ! git -C "$CHECKOUT" diff --full-index --no-ext-diff --no-color | cmp -s "$PATCH" -; then
    printf 'FluidAudio changes differ from the reviewed patch; leaving them untouched.\n' >&2
    exit 1
fi
printf 'FluidAudio local fixes verified.\n'
