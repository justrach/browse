#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
swiftc -swift-version 5 \
  tests/history/HistoryChecks.swift \
  Sources/Browse/History.swift Sources/Browse/Searched.swift \
  Sources/Browse/Engine.swift Sources/Browse/Address.swift \
  -o "$SCRATCH/history-checks"
HISTORY_TEST_DIR="$SCRATCH/profile" "$SCRATCH/history-checks"
