#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
swiftc -swift-version 5 \
  tests/chromium-import/ChromiumChecks.swift \
  Sources/Browse/Import.swift \
  -o "$SCRATCH/chromium-checks"
CHROMIUM_TEST_DIR="$SCRATCH/profile" "$SCRATCH/chromium-checks"
