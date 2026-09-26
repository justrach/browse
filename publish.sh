#!/bin/bash
# Puts the three files people and the updater read where they can read them:
# the disk image for people, the ZIP for the updater, and the appcast that
# names them both.
#
#   ./publish.sh github            a GitHub release, vVERSION, on justrach/browse
#   ./publish.sh <folder>          or a folder a site serves
#
# ./build.sh release ship makes them first (release dmg makes them too, but
# unnotarised — fine for trying, not for anyone else's Mac). The names never
# change, so the links never have to: the app reads
# releases/latest/download/appcast.json, which is always the newest release's.
set -euo pipefail

cd "$(dirname "$0")"
[ $# -eq 1 ] || { echo "usage: ./publish.sh github | <folder>" >&2; exit 1; }
FILES=(browse.dmg browse.zip appcast.json)
VERSION="$(tr -d '[:space:]' < VERSION)"

for FILE in "${FILES[@]}"; do
  [ -f "build/$FILE" ] || { echo "build/$FILE is missing — run ./build.sh release ship" >&2; exit 1; }
done
[ -d build/browse.app ] || { echo "build/browse.app is missing — run ./build.sh release ship" >&2; exit 1; }
codesign --verify --deep --strict build/browse.app \
  || { echo "build/browse.app has an invalid signature" >&2; exit 1; }
TEAM="$(codesign -dv --verbose=4 build/browse.app 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[ "$TEAM" = "WWP9DLJ27P" ] \
  || { echo "build/browse.app is not signed by Developer ID team WWP9DLJ27P" >&2; exit 1; }
DMG_TEAM="$(codesign -dv --verbose=4 build/browse.dmg 2>&1 | sed -n 's/^TeamIdentifier=//p')"
[ "$DMG_TEAM" = "WWP9DLJ27P" ] \
  || { echo "build/browse.dmg is not signed by Developer ID team WWP9DLJ27P" >&2; exit 1; }
xcrun stapler validate -q build/browse.dmg >/dev/null 2>&1 \
  || { echo "build/browse.dmg is not notarised and stapled" >&2; exit 1; }
spctl --assess --type open --context context:primary-signature build/browse.dmg \
  || { echo "build/browse.dmg failed Gatekeeper assessment" >&2; exit 1; }
python3 - "$VERSION" "$1" <<'PY'
import hashlib, json, plistlib, sys
version, destination = sys.argv[1:]
with open("build/browse.app/Contents/Info.plist", "rb") as source:
    info = plistlib.load(source)
with open("build/appcast.json") as source:
    feed = json.load(source)
digest = hashlib.sha256()
with open("build/browse.zip", "rb") as source:
    for block in iter(lambda: source.read(1024 * 1024), b""):
        digest.update(block)
if (info.get("CFBundleIdentifier") != "com.codegraff.search"
        or info.get("CFBundleShortVersionString") != version
        or feed.get("version") != version
        or str(feed.get("build")) != str(info.get("CFBundleVersion"))
        or feed.get("sha256") != digest.hexdigest()):
    sys.exit("app, VERSION, ZIP and appcast metadata do not agree")
if destination == "github":
    base = f"https://github.com/justrach/browse/releases/download/v{version}"
    if feed.get("url") != f"{base}/browse.zip" or feed.get("dmg") != f"{base}/browse.dmg":
        sys.exit("appcast download URLs do not name this GitHub release")
PY

if [ "$1" = "github" ]; then
  REPO="justrach/browse"
  gh release view "v$VERSION" -R "$REPO" >/dev/null 2>&1 \
    && { echo "v$VERSION is already released — raise VERSION first" >&2; exit 1; }
  # The first paragraph of NOTES.md is what's new, the same line Settings shows.
  NOTES="$(awk 'NF { printf "%s%s", (n++ ? " " : ""), $0; next } n { exit }' NOTES.md)"
  gh release create "v$VERSION" -R "$REPO" --target main \
    --title "browse $VERSION" --notes "$NOTES" \
    "${FILES[@]/#/build/}"
  exit 0
fi

FOLDER="$1"
mkdir -p "$FOLDER"
for FILE in "${FILES[@]}"; do
  cp "build/$FILE" "$FOLDER/$FILE"
  echo "copied: build/$FILE → $FOLDER/$FILE"
done
