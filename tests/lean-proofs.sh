#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../lean-proofs"

# Guard: zero sorry / axiom allowed in formal proofs.
if rg -n '\b(sorry|axiom)\b' Browse/ Main.lean; then
  echo "FAIL: sorry or axiom found in lean-proofs/" >&2
  exit 1
fi

lake build
./.lake/build/bin/browse-spec-report
