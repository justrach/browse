#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

python3 tests/ui-layout/check_sources.py

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp/}browse-ui-layout.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT
swiftc -swift-version 5 -parse-as-library \
  Sources/Browse/Plate.swift \
  tests/ui-layout/main.swift \
  -o "$SCRATCH/ui-layout"
"$SCRATCH/ui-layout"
