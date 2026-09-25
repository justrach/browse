#!/bin/bash
# Update a fork-owned Homebrew tap after publishing a Codegraff release.
# Required environment:
#   CODEGRAFF_TAP_REPO   Git URL of a tap you control
#   CODEGRAFF_CASK_PATH  Cask path within that tap (for example Casks/search-codegraff-app.rb)
#   CODEGRAFF_RELEASE_URL  URL of this version's search.codegraff.app.dmg
# No repository or tap is a default.
set -euo pipefail

cd "$(dirname "$0")"
: "${CODEGRAFF_TAP_REPO:?set CODEGRAFF_TAP_REPO to a fork-owned tap}"
: "${CODEGRAFF_CASK_PATH:?set CODEGRAFF_CASK_PATH within that tap}"
: "${CODEGRAFF_RELEASE_URL:?set CODEGRAFF_RELEASE_URL to this fork's DMG}"
VERSION="$(tr -d '[:space:]' < VERSION)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

curl -fsSL -o "$WORK/search.codegraff.app.dmg" "$CODEGRAFF_RELEASE_URL"
SHA="$(shasum -a 256 "$WORK/search.codegraff.app.dmg" | cut -d' ' -f1)"
git clone -q "$CODEGRAFF_TAP_REPO" "$WORK/tap"
CASK="$WORK/tap/$CODEGRAFF_CASK_PATH"
[ -f "$CASK" ] || { echo "missing cask: $CODEGRAFF_CASK_PATH" >&2; exit 1; }
sed -i '' -E "s/^  version \".*\"/  version \"$VERSION\"/; s/^  sha256 \".*\"/  sha256 \"$SHA\"/" "$CASK"
if git -C "$WORK/tap" diff --quiet; then
  echo "the tap already has search.codegraff.app $VERSION"
  exit 0
fi
git -C "$WORK/tap" commit -qam "search.codegraff.app $VERSION"
git -C "$WORK/tap" push -q
echo "tap: search.codegraff.app $VERSION, sha256 $SHA"
