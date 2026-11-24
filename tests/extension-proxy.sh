#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp/}browse-proxy.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT
swiftc -swift-version 5 -parse-as-library \
  -DEXTENSION_PROXY_STANDALONE \
  Sources/Browse/ExtensionProxy.swift \
  tests/extension-proxy/main.swift \
  -o "$SCRATCH/extension-proxy"
"$SCRATCH/extension-proxy"
