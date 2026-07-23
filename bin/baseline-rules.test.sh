#!/usr/bin/env bash
# What: tests for baseline-rules.sh. Where: quality-kit/bin.
# Why:  onboarding generates the burn-down from this; a wrong rule-id form
#       yields overrides that silently match nothing.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
BR="$DIR/baseline-rules.sh"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }

# --- rule-id normalization is pure logic: test it without any toolchain ---
# eslint core rules are keyed bare in oxlint configs; everything else is
# plugin/rule. Diagnostics always use plugin(rule).
norm_cases='eslint(func-style)|func-style
unicorn(filename-case)|unicorn/filename-case
typescript(consistent-type-imports)|typescript/consistent-type-imports
jsx-a11y(prefer-tag-over-role)|jsx-a11y/prefer-tag-over-role
react(react-compiler)|react/react-compiler'
while IFS='|' read -r code want; do
  got="$(bash "$BR" --norm "$code")"
  [ "$got" = "$want" ] && ok "normalize $code" || bad "normalize $code" "got=$got want=$want"
done <<<"$norm_cases"

# --- python path: real ruff, real counts ---
if command -v uvx >/dev/null 2>&1; then
  P="$(mktemp -d)"
  printf '{"version":"0.2.0","profile":"python","runner":"make","pendingFlags":[],"ruleOverrides":{"burnDown":{},"permanent":{}},"ignoreOverrides":[]}\n' > "$P/.quality-kit.json"
  printf 'line-length = 100\ntarget-version = "py312"\n\n[lint]\nextend-select = ["B", "I", "UP"]\n' > "$P/ruff.toml"
  # two unused imports (F401), one unsorted-import block (I001)
  printf 'import sys\nimport os\n\nx = 1\n' > "$P/a.py"
  printf 'import json\n\ny = 2\n' > "$P/b.py"
  out="$(bash "$BR" "$P" 2>/dev/null)"
  python3 -c "
import json,sys
d=json.loads('''$out''')
assert d.get('F401')==3, ('expected 3 unused imports, got', d)
assert list(d)==sorted(d), ('keys must be sorted', list(d))
assert all(isinstance(v,int) and v>0 for v in d.values()), d
" && ok "python counts per rule" || bad "python counts per rule" "$out"
  # --- linter ran but failed (malformed config): distinct exit 4, not an
  # empty-but-successful baseline. ruff still exits non-zero here despite
  # --exit-zero, because this is a config/usage failure, not "0 violations".
  C="$(mktemp -d)"
  printf '{"version":"0.2.0","profile":"python","runner":"make","pendingFlags":[],"ruleOverrides":{"burnDown":{},"permanent":{}},"ignoreOverrides":[]}\n' > "$C/.quality-kit.json"
  printf 'this is not valid toml [[[\n' > "$C/ruff.toml"
  printf 'import os\n' > "$C/a.py"
  rc=0; out="$(bash "$BR" "$C" 2>/dev/null)" || rc=$?
  [ "$rc" = 4 ] && [ "$out" = "{}" ] && ok "malformed ruff config yields exit 4, not an empty success" || bad "malformed ruff config yields exit 4, not an empty success" "rc=$rc out=$out"
  err="$(bash "$BR" "$C" 2>&1 >/dev/null)" || true
  echo "$err" | grep -q "baseline-rules.sh" && ok "malformed config names the failure on stderr" || bad "malformed config names the failure on stderr" "no guidance on stderr"
else
  echo "SKIP python baseline (no uvx available)"
fi

# --- absent toolchain: loud failure (exit 3), but stdout stays machine-usable ---
# "couldn't count" must be distinguishable from "counted zero" — a caller that
# blindly trusted an empty-but-successful baseline would silently ratchet
# nothing. stdout still carries {} so a caller that DOES want to tolerate this
# (Task 6's stamp-seeding: `... || echo '{}'`) still gets valid JSON either way.
E="$(mktemp -d)"
printf '{"version":"0.2.0","profile":"nextjs","runner":"npm","pendingFlags":[],"ruleOverrides":{"burnDown":{},"permanent":{}},"ignoreOverrides":[]}\n' > "$E/.quality-kit.json"
rc=0; out="$(bash "$BR" "$E" 2>/dev/null)" || rc=$?
[ "$rc" = 3 ] && [ "$out" = "{}" ] && ok "missing toolchain yields empty object, exit 3" || bad "missing toolchain yields empty object, exit 3" "rc=$rc out=$out"
err="$(bash "$BR" "$E" 2>&1 >/dev/null)" || true  # exit 3 is expected here; only grepping its stderr
echo "$err" | grep -q "baseline-rules.sh" && ok "missing toolchain names the follow-up command" || bad "missing toolchain names the follow-up command" "no guidance on stderr"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
