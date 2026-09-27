#!/bin/bash
# A new version, handed to CI: the number raised, the notes written, a
# commit and a tag pushed. The tag starts .github/workflows/release.yml,
# which builds, signs, notarises and publishes — and the updater in every
# installed copy finds it from there.
#
#   ./release.sh 1.1.0 "What's new, in a paragraph."   from main: cuts release/v1.1
#   ./release.sh 1.1.1 "What's new, in a paragraph."   from release/v1.1: a fix
#
# Every X.Y has a branch of its own, release/vX.Y, and its tags are made
# there and nowhere else. An X.Y.0 cuts that branch from main; a fix for a
# line that's out goes to main first, is cherry-picked onto its release
# branch (git cherry-pick -x), and is released from there. Either way the
# version's commit is merged back into main, so main's VERSION and CHANGELOG
# know what shipped.
#
# The paragraph goes at the top of NOTES.md (the line under the version in
# Settings, and the release's notes); CHANGELOG's Unreleased becomes this
# version's section.
set -euo pipefail

cd "$(dirname "$0")"
[ $# -eq 2 ] || { echo 'usage: ./release.sh X.Y.Z "What'\''s new, in a paragraph."' >&2; exit 1; }
VERSION="$1"
NOTES="$2"
[[ "$VERSION" =~ ^([0-9]+\.[0-9]+)\.([0-9]+)$ ]] || { echo "a version is three numbers, like 1.0.2" >&2; exit 1; }
LINE="${BASH_REMATCH[1]}"
PATCH="${BASH_REMATCH[2]}"
BRANCH="release/v$LINE"
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "commit or put away what's changed first" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && { echo "v$VERSION is already a tag" >&2; exit 1; }
git fetch -q origin

HERE="$(git rev-parse --abbrev-ref HEAD)"
if [ "$HERE" = main ]; then
  [ "$PATCH" = 0 ] || { echo "a fix goes out from its line's branch: git switch $BRANCH, cherry-pick it, run this there" >&2; exit 1; }
  [ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "main isn't the same as origin/main — pull or push first" >&2; exit 1; }
  git rev-parse -q --verify "refs/remotes/origin/$BRANCH" >/dev/null && { echo "$BRANCH is cut already — release from it" >&2; exit 1; }
  git switch -q -c "$BRANCH"
  echo "cut $BRANCH from main"
elif [ "$HERE" = "$BRANCH" ]; then
  [ "$PATCH" != 0 ] || { echo "$BRANCH is out already; its next version is a fix, $LINE.1 or on" >&2; exit 1; }
  [ "$(git rev-parse HEAD)" = "$(git rev-parse "origin/$BRANCH")" ] || { echo "$BRANCH isn't the same as origin/$BRANCH — pull or push first" >&2; exit 1; }
else
  echo "$VERSION goes out from main (an X.Y.0) or from $BRANCH (a fix), not from $HERE" >&2; exit 1
fi

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
git push -q -u origin "$BRANCH" "v$VERSION"
echo "v$VERSION pushed from $BRANCH — the release workflow takes it from here:"
echo "  gh run watch -R justrach/browse \$(gh run list -R justrach/browse -w release -L 1 --json databaseId -q '.[0].databaseId')"

# Back into main. A cut is a fast-forward; a fix can meet main's newer
# CHANGELOG, and that merge is left to be finished by hand.
git switch -q main
git pull -q --ff-only origin main
if git merge -q --no-edit -m "Merge $BRANCH: browse $VERSION" "$BRANCH"; then
  git push -q origin main
  echo "merged $BRANCH back into main"
else
  git merge --abort
  echo "$BRANCH didn't merge back cleanly: git merge $BRANCH on main, keep both CHANGELOG sections, push" >&2
  exit 1
fi
