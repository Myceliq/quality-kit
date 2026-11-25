#!/usr/bin/env bash
# What: every single code py/ruff.toml selects by name (N801, PT011, RET503, ...) is
#       proved on its own fixture pair in py/rule-fixtures/<CODE>/: ruff with the
#       shipped config reports exactly that code on test_incorrect.py and nothing on
#       test_correct.py.
# Where: quality-kit/py.
# Why:  a selected code only gates what ruff actually reports for it. A code dropped
#       from extend-select, a fixture that trips some other rule, or a code added with
#       no fixture would each claim enforcement nobody checked (#134, #136). Family
#       selectors (B, I, UP, S) are whole plugins and are not fixtured here.
#       Fixture files are named test_*.py so the shipped S101 test-file ignore applies
#       to PT017's assert, exactly as it does in a consumer's tests.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
FX="$DIR/rule-fixtures"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }

# The ruff issue #134 measured with (software-factory's pin). The kit pins no ruff of
# its own; a different ruff can change what a code flags, so any other version is refused.
PIN="0.15.2"
if [ -n "${RUFF_BIN:-}" ]; then RUFF=("$RUFF_BIN")
elif [ "$(ruff --version 2>/dev/null || true)" = "ruff $PIN" ]; then RUFF=(ruff)
elif command -v uvx >/dev/null 2>&1; then RUFF=(uvx "ruff@$PIN")
else
  echo "SKIP ruff rule fixtures (set RUFF_BIN to ruff $PIN, or install uvx)"
  exit 0
fi
ver="$("${RUFF[@]}" --version 2>&1 || true)"
if [ "$ver" != "ruff $PIN" ]; then
  bad "ruff is the pinned $PIN" "${RUFF[*]} reports '$ver'"
  echo FAILURES; exit 1
fi
ok "ruff is the pinned $PIN"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# check CONFIG — one "<code>|<problem>" line per problem with CONFIG over a copy of
# the fixtures; prints nothing when every selected code's pair holds. One ruff run
# over the whole tree, grouped per file from its JSON output. Each run gets its own
# mktemp dir: check runs inside $(...), so a counter would never advance.
check() {
  local w
  w="$(mktemp -d -p "$TMP")"
  cp "$1" "$w/ruff.toml"
  cp -R "$FX" "$w/fx"
  local rc=0
  (cd "$w" && "${RUFF[@]}" check --config ruff.toml --no-cache --exit-zero --output-format json fx >"$w/out.json" 2>"$w/err") || rc=$?
  if [ "$rc" != 0 ]; then echo "ruff|ruff exited $rc: $(cat "$w/err")"; return 0; fi
  python3 - "$w" <<'PY'
import json, os, re, sys, tomllib
w = sys.argv[1]
fx = os.path.join(w, "fx")
sel = tomllib.load(open(os.path.join(w, "ruff.toml"), "rb"))["lint"]["extend-select"]
named = {c for c in sel if re.fullmatch(r"[A-Z]+[0-9]+", c)}
dirs = set(os.listdir(fx))
got = {}
for d in json.load(open(os.path.join(w, "out.json"))):
    rel = os.path.relpath(d["filename"], fx)
    got.setdefault(rel, []).append(d["code"])
for c in sorted(named - dirs):
    print(f"{c}|selected but has no fixture dir py/rule-fixtures/{c}")
for c in sorted(dirs - named):
    print(f"{c}|has fixtures but is not selected by name in extend-select")
for c in sorted(dirs):
    for f in ("test_incorrect.py", "test_correct.py"):
        if not os.path.isfile(os.path.join(fx, c, f)):
            print(f"{c}|missing {f}")
    bad = got.get(f"{c}/test_incorrect.py", [])
    if sorted(set(bad)) != [c]:
        print(f"{c}|test_incorrect.py raised {sorted(bad)}, want exactly [{c!r}]")
    good = got.get(f"{c}/test_correct.py", [])
    if good:
        print(f"{c}|test_correct.py raised {sorted(good)}, want nothing")
PY
}

out="$(check "$DIR/ruff.toml")"
LABEL="every named code fails its incorrect example and passes its correct one"
if [ -z "$out" ]; then ok "$LABEL"; else
  while IFS='|' read -r c detail; do bad "$LABEL" "$c: $detail"; done <<<"$out"
fi

# Negative arms, on a copy of py/ruff.toml (never the real file); the check must name
# what was broken.
# drop CODE — writes a copy of the shipped config without CODE in extend-select.
drop() {
  python3 - "$DIR/ruff.toml" "$1" "$TMP/drop-$1.toml" <<'PY'
import sys
src, code, dst = sys.argv[1:]
text = open(src).read()
needle = f'"{code}", '
assert text.count(needle) == 1, f"{code} is not in extend-select exactly once"
open(dst, "w").write(text.replace(needle, "", 1))
PY
}
# Every named code, not one sample: removing any of them must turn the check red.
for c in $(ls "$FX"); do
  drop "$c" 2>/dev/null || { bad "arm: removing $c from extend-select is caught" "$c is not in extend-select exactly once"; continue; }
  got="$(check "$TMP/drop-$c.toml")"
  grep -q "^$c|test_incorrect.py raised \[\]" <<<"$got" \
    && ok "arm: removing $c from extend-select is caught" \
    || bad "arm: removing $c from extend-select is caught" "check reported: ${got//$'\n'/ }"
done

# A correct example that trips its code is caught.
cp -R "$FX" "$TMP/fx-saved"
cp "$FX/RET505/test_incorrect.py" "$TMP/swap.py"
FX="$TMP/fx-arm"; cp -R "$TMP/fx-saved" "$FX"; cp "$TMP/swap.py" "$FX/RET505/test_correct.py"
grep -q "^RET505|test_correct.py raised \['RET505'\]" <<<"$(check "$DIR/ruff.toml")" \
  && ok "arm: a flagged correct example is caught" || bad "arm: a flagged correct example is caught" "not reported"

# An incorrect example that also trips another code is caught (not "exactly" its code).
FX="$TMP/fx-arm2"; cp -R "$TMP/fx-saved" "$FX"; printf 'import os\n' >>"$FX/N801/test_incorrect.py"
grep -q "^N801|test_incorrect.py raised .*F401" <<<"$(check "$DIR/ruff.toml")" \
  && ok "arm: an incorrect example raising a second code is caught" || bad "arm: an incorrect example raising a second code is caught" "not reported"

# A code selected with no fixture dir is caught.
FX="$TMP/fx-arm3"; cp -R "$TMP/fx-saved" "$FX"; rm -r "$FX/PT011"
grep -q "^PT011|selected but has no fixture dir" <<<"$(check "$DIR/ruff.toml")" \
  && ok "arm: a selected code with no fixtures is caught" || bad "arm: a selected code with no fixtures is caught" "not reported"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
