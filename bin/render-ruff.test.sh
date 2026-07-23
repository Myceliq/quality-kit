#!/usr/bin/env bash
# What: tests for render-ruff.sh. Where: quality-kit/bin.
# Why:  ruff can't execute logic, so python's override wiring is baked into a
#       rendered file — determinism is what lets the drift gate trust it.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
KITROOT="$(cd "$DIR/.." && pwd)"
RR="$DIR/render-ruff.sh"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }

mk() { # repo with the given ruleOverrides/ignoreOverrides
  local r; r="$(mktemp -d)"
  printf '%s\n' "$1" > "$r/.quality-kit.json"
  echo "$r"
}

# no overrides → byte-identical to the kit base
R="$(mk '{"version":"0.2.0","profile":"python","runner":"make","pendingFlags":[],"ruleOverrides":{"burnDown":{},"permanent":{}},"ignoreOverrides":[]}')"
bash "$RR" "$R" > "$R/out.toml"
cmp -s "$KITROOT/py/ruff.toml" "$R/out.toml" && ok "no overrides renders the kit base verbatim" || bad "no overrides renders the kit base verbatim" "$(diff "$KITROOT/py/ruff.toml" "$R/out.toml" || true)"

# determinism: same input, same bytes, twice
bash "$RR" "$R" > "$R/out2.toml"
cmp -s "$R/out.toml" "$R/out2.toml" && ok "render is deterministic" || bad "render is deterministic" "differs between runs"

# overrides land in the right sections
R="$(mk '{"version":"0.2.0","profile":"python","runner":"make","pendingFlags":[],"ruleOverrides":{"burnDown":{"F401":9,"B008":2},"permanent":{"UP006":{"level":"off","why":"py312 target predates the rewrite"}}},"ignoreOverrides":["vendor/**","src/generated/**"]}')"
bash "$RR" "$R" > "$R/out.toml"
python3 -c "
import sys
t=open('$R/out.toml').read()
lines=[l for l in t.splitlines()]
ei=[i for i,l in enumerate(lines) if l.startswith('extend-exclude')]
li=[i for i,l in enumerate(lines) if l.strip()=='[lint]']
ig=[i for i,l in enumerate(lines) if l.startswith('extend-ignore')]
assert ei and li and ig, ('missing keys', lines)
assert ei[0] < li[0], 'extend-exclude must be TOP-LEVEL (before [lint]) or ruff errors on the unknown key'
assert ig[0] > li[0], 'extend-ignore must sit inside [lint]'
assert t.count('[lint]')==1, 'duplicate [lint] table is a TOML error'
assert '\"B008\", \"F401\"' in t, ('burnDown+permanent rules must be sorted for determinism', t)
assert '\"UP006\"' in t, 'permanent rules must be ignored too'
assert '\"src/generated/**\", \"vendor/**\"' in t, ('ignoreOverrides must be sorted', t)
" && ok "sections spliced correctly, sorted" || bad "sections spliced correctly, sorted" "$(cat "$R/out.toml")"

# the rendered file must be valid TOML that ruff itself accepts
if command -v uvx >/dev/null 2>&1; then
  cp "$R/out.toml" "$R/ruff.toml"; printf 'import os\n' > "$R/probe.py"
  (cd "$R" && uvx ruff check --exit-zero . >/dev/null 2>&1) \
    && ok "rendered ruff.toml is accepted by ruff" || bad "rendered ruff.toml is accepted by ruff" "ruff rejected the file"
else
  echo "SKIP ruff acceptance (no uvx available)"
fi

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
