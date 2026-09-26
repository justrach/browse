#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
swiftc -swift-version 5 \
  tests/safari-import/SafariImportChecks.swift \
  Sources/Browse/SafariImport.swift \
  -o "$SCRATCH/safari-import-checks"
SAFARI_TEST_DIR="$SCRATCH" "$SCRATCH/safari-import-checks"
