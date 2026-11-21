#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp/}browse-markdown.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT
swiftc -swift-version 5 -parse-as-library \
  Sources/Browse/MarkdownView.swift \
  tests/markdown-latex/main.swift \
  -o "$SCRATCH/markdown-latex"
"$SCRATCH/markdown-latex"
