#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp/}browse-scheme.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT
swiftc -swift-version 5 -parse-as-library \
  Sources/Browse/BrowseScheme.swift \
  tests/browse-scheme/main.swift \
  -o "$SCRATCH/browse-scheme"
"$SCRATCH/browse-scheme"
