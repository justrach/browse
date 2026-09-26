#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
swiftc -swift-version 5 \
  Sources/Browse/Searched.swift \
  Sources/Browse/GoogleSuggestions.swift \
  tests/search-suggestions/main.swift \
  -o "$SCRATCH/search-suggestions"
"$SCRATCH/search-suggestions"
