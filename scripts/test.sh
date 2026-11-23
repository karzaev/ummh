#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/prepare-dependencies.sh
exec swift test "$@"
