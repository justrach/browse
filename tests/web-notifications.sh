#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp/}browse-webnotif.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT
swiftc -swift-version 5 -parse-as-library \
  -DWEB_NOTIFICATIONS_STANDALONE \
  Sources/Browse/WebNotifications.swift \
  tests/web-notifications/main.swift \
  -o "$SCRATCH/web-notifications"
"$SCRATCH/web-notifications"
