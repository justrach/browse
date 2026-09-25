#!/bin/bash
# Puts the three files people and the updater read where they can read them:
# the disk image for people, the ZIP for the updater, and the appcast that
# names them both.
#
#   ./publish.sh github            a GitHub release, vVERSION, on justrach/search
#   ./publish.sh <folder>          or a folder a site serves
#
# ./build.sh release ship makes them first (release dmg makes them too, but
# unnotarised — fine for trying, not for anyone else's Mac). The names never
# change, so the links never have to: the app reads
# releases/latest/download/appcast.json, which is always the newest release's.
set -euo pipefail

cd "$(dirname "$0")"
[ $# -eq 1 ] || { echo "usage: ./publish.sh github | <folder>" >&2; exit 1; }
FILES=(search.codegraff.app.dmg search.codegraff.app.zip appcast.json)
VERSION="$(tr -d '[:space:]' < VERSION)"

for FILE in "${FILES[@]}"; do
  [ -f "build/$FILE" ] || { echo "build/$FILE is missing — run ./build.sh release ship" >&2; exit 1; }
done
xcrun stapler validate -q "build/search.codegraff.app.dmg" >/dev/null 2>&1 \
  || echo "note: build/search.codegraff.app.dmg is not notarised — ./build.sh release ship does that" >&2

if [ "$1" = "github" ]; then
  REPO="justrach/search"
  # The appcast has to name this release, or the updater would fetch another
  # version's ZIP — or nothing.
  grep -q "/releases/download/v$VERSION/" build/appcast.json \
    || { echo "build/appcast.json doesn't name v$VERSION — rebuild without SEARCH_DOWNLOAD_URL" >&2; exit 1; }
  gh release view "v$VERSION" -R "$REPO" >/dev/null 2>&1 \
    && { echo "v$VERSION is already released — raise VERSION first" >&2; exit 1; }
  # The first paragraph of NOTES.md is what's new, the same line Settings shows.
  NOTES="$(awk 'NF { printf "%s%s", (n++ ? " " : ""), $0; next } n { exit }' NOTES.md)"
  gh release create "v$VERSION" -R "$REPO" --target main \
    --title "search.codegraff.app $VERSION" --notes "$NOTES" \
    "${FILES[@]/#/build/}"
  exit 0
fi

FOLDER="$1"
mkdir -p "$FOLDER"
for FILE in "${FILES[@]}"; do
  cp "build/$FILE" "$FOLDER/$FILE"
  echo "copied: build/$FILE → $FOLDER/$FILE"
done
