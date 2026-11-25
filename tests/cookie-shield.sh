#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp/}browse-cookieshield.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT
swiftc -swift-version 5 -parse-as-library \
  Sources/Browse/CookieShield.swift \
  tests/cookie-shield/main.swift \
  -o "$SCRATCH/cookie-shield"
"$SCRATCH/cookie-shield"
