#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp/}browse-sitesearch.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT
swiftc -swift-version 5 -parse-as-library \
  Sources/Browse/Engine.swift \
  Sources/Browse/SiteSearch.swift \
  tests/site-search/main.swift \
  -o "$SCRATCH/site-search"
"$SCRATCH/site-search"
