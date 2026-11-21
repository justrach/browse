#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp/}browse-passkeys.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT
swiftc -swift-version 5 -parse-as-library \
  Sources/Browse/Registrable.swift \
  Sources/Browse/Passkeys.swift \
  tests/passkeys/main.swift \
  -o "$SCRATCH/passkeys"
"$SCRATCH/passkeys"
