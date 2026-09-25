#!/bin/bash
# A new version, handed to CI: the number raised, the notes written, a
# commit and a tag pushed. The tag starts .github/workflows/release.yml,
# which builds, signs, notarises and publishes — and the updater in every
# installed copy finds it from there.
#
#   ./release.sh 1.0.2 "What's new, in a paragraph."
#
# The paragraph goes at the top of NOTES.md (the line under the version in
# Settings, and the release's notes); CHANGELOG's Unreleased becomes this
# version's section.
set -euo pipefail

cd "$(dirname "$0")"
[ $# -eq 2 ] || { echo 'usage: ./release.sh X.Y.Z "What'\''s new, in a paragraph."' >&2; exit 1; }
VERSION="$1"
NOTES="$2"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "a version is three numbers, like 1.0.2" >&2; exit 1; }
[ "$(git rev-parse --abbrev-ref HEAD)" = "main" ] || { echo "releases go from main" >&2; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "commit or put away what's changed first" >&2; exit 1; }
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "main isn't the same as origin/main — pull or push first" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && { echo "v$VERSION is already a tag" >&2; exit 1; }

# Newer than what's out, by the numbers.
CURRENT="$(tr -d '[:space:]' < VERSION)"
[ "$(printf '%s\n%s\n' "$CURRENT" "$VERSION" | sort -V | tail -1)" = "$VERSION" ] && [ "$CURRENT" != "$VERSION" ] \
  || { echo "$VERSION isn't newer than $CURRENT" >&2; exit 1; }

echo "$VERSION" > VERSION
{ printf '%s\n\n' "$NOTES"; cat NOTES.md; } > NOTES.md.new && mv NOTES.md.new NOTES.md
python3 - "$VERSION" <<'PY'
import sys, datetime
version = sys.argv[1]
text = open("CHANGELOG.md").read()
head = "## Unreleased"
assert head in text, "CHANGELOG.md has no Unreleased section"
dated = f"## {version} — {datetime.date.today():%-d %B %Y}"
open("CHANGELOG.md", "w").write(text.replace(head, f"{head}\n\n{dated}", 1))
PY

git add VERSION NOTES.md CHANGELOG.md
git commit -q -m "browse $VERSION"
git tag -a "v$VERSION" -m "browse $VERSION"
git push -q origin main "v$VERSION"
echo "v$VERSION pushed — the release workflow takes it from here:"
echo "  gh run watch -R justrach/browse \$(gh run list -R justrach/browse -w release -L 1 --json databaseId -q '.[0].databaseId')"
