#!/usr/bin/env bash
# What: ts/react-rules/ stays the pinned, never-edited upstream bytes, and
#       coverage.json maps every vendored rule to what enforces it.
# Where: quality-kit/ts.
# Why:  the coverage table is only worth reading while it matches the files it
#       describes: a rule added or dropped by a pin bump, an edited vendored
#       byte, or an `oxlint` row naming a rule the nextjs profile does not
#       enforce at error would each make it claim coverage nobody has.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
KITROOT="$(cd "$DIR/.." && pwd)"
RULES="$DIR/react-rules"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

ROWS="coverage rows match the vendored rule files"
VALUES="coverage row values are valid"
BYTES="vendored bytes match SOURCE.json"

# check D — prints one "<label>|<detail>" line per problem in the react-rules
# tree at D; prints nothing when it is clean. Rule ids are the stems of the
# non-`_` *.md files in best-practices/ and composition/, plus one id for the
# single web-interface-guidelines.md file.
check() {
  local d="$1"
  python3 - "$d" "$ROWS" "$VALUES" <<'PY'
import json, os, sys
d, ROWS, VALUES = sys.argv[1:]
want = {}
for sub in ("best-practices", "composition"):
    for f in sorted(os.listdir(os.path.join(d, sub))):
        if f.endswith(".md") and not f.startswith("_"):
            k = f[:-3]
            if k in want:
                print(f"{ROWS}|{k} is the id of both {want[k]} and {sub}/{f}")
            want[k] = f"{sub}/{f}"
if os.path.isfile(os.path.join(d, "web-interface-guidelines.md")):
    want["web-interface-guidelines"] = "web-interface-guidelines.md"
try:
    rows = json.load(open(os.path.join(d, "coverage.json")))
except (OSError, ValueError) as e:
    print(f"{ROWS}|coverage.json is unreadable: {e}")
    sys.exit(0)
if not isinstance(rows, dict):
    print(f"{ROWS}|coverage.json is not a JSON object")
    sys.exit(0)
for k in sorted(want.keys() - rows.keys()):
    print(f"{ROWS}|no row for {k} ({want[k]})")
for k in sorted(rows.keys() - want.keys()):
    print(f"{ROWS}|row {k} names no vendored rule file")
for k, r in sorted(rows.items()):
    if not isinstance(r, dict) or sorted(r) != ["by", "rule", "static_export", "why"]:
        print(f"{VALUES}|{k} must have exactly the keys by, rule, static_export, why")
        continue
    if r["by"] not in ("oxlint", "custom", "review"):
        print(f"{VALUES}|{k} has by={r['by']!r}, want oxlint, custom or review")
    if r["static_export"] not in ("applies", "n/a"):
        print(f"{VALUES}|{k} has static_export={r['static_export']!r}, want applies or n/a")
    if not isinstance(r["why"], str) or not r["why"].strip():
        print(f"{VALUES}|{k} has an empty why")
    if r["by"] == "oxlint":
        if not isinstance(r["rule"], str) or not r["rule"].strip():
            print(f"{VALUES}|{k} is by oxlint but names no rule")
    elif r["rule"] is not None:
        print(f"{VALUES}|{k} is by {r['by']} but its rule is {r['rule']!r}, want null")
PY
  local list="$TMP/pinned.txt"
  python3 - "$d/SOURCE.json" >"$list" <<'PY' || { echo "$BYTES|SOURCE.json is unreadable"; return 0; }
import json, sys
for s in json.load(open(sys.argv[1]))["sources"]:
    for p, h in s["files"].items():
        print(p, h)
PY
  [ -s "$list" ] || { echo "$BYTES|SOURCE.json lists no files"; return 0; }
  local p h got
  while read -r p h; do
    got="$(sha256sum "$d/$p" 2>/dev/null | cut -d' ' -f1)" || got=""
    [ "$got" = "$h" ] || echo "$BYTES|$p has sha256 ${got:-<missing>}, SOURCE.json pins $h"
  done <"$list"
}

# report LABEL OUT — PASS LABEL when OUT holds no problem for it, else one FAIL per problem.
report() {
  local hits l detail
  hits="$(grep -F "$1|" <<<"$2" || true)"
  if [ -z "$hits" ]; then ok "$1"; return; fi
  while IFS='|' read -r l detail; do bad "$l" "$detail"; done <<<"$hits"
}

out="$(check "$RULES")"
for label in "$ROWS" "$VALUES" "$BYTES"; do report "$label" "$out"; done

# Negative arms: each mutates a fresh copy of ts/react-rules/, never the real tree,
# and the check must name what was broken.
n=0
T=""
fresh() { n=$((n + 1)); T="$TMP/arm$n"; cp -R "$RULES" "$T"; }
# mutate PY — runs the statement PY against the copy's coverage.json as `rows`.
mutate() {
  python3 - "$T/coverage.json" "$1" <<'PY'
import json, sys
path, stmt = sys.argv[1:]
rows = json.load(open(path))
exec(stmt)
json.dump(rows, open(path, "w"), indent=2)
PY
}
caught() {
  local got; got="$(check "$T")"
  grep -qF -- "$2" <<<"$got" && ok "arm: $1" || bad "arm: $1" "check did not report $2"
}

fresh; mutate 'rows.pop("rerender-memo", None)'
caught "a removed row is caught" "rerender-memo"
fresh; mutate 'rows["not-a-rule"] = {"by": "review", "rule": None, "static_export": "applies", "why": "x"}'
caught "a row naming no vendored file is caught" "not-a-rule"
fresh; printf 'x' >>"$T/composition/state-lift-state.md"
caught "an edited byte is caught" "composition/state-lift-state.md"
fresh; mutate 'rows["async-api-routes"]["why"] = "  "'
caught "an empty why is caught" "async-api-routes"

# Every `oxlint` row must name a rule the nextjs profile resolves at error, read
# from the pinned oxlint's own --print-config of the shipped config — never from
# a hand-written list. Needs an oxlint whose node_modules also has ultracite (the
# config imports ultracite/oxlint/*); unset OXLINT_BIN skips, as in
# oxlint-overrides.test.sh.
OXLINT="${OXLINT_BIN:-}"
if [ -z "$OXLINT" ]; then
  echo "SKIP oxlint severity check (set OXLINT_BIN to the pinned oxlint whose node_modules has ultracite)"
else
  pin="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["oxlint"])' "$KITROOT/ts/pins.json")"
  ver="$("$OXLINT" --version 2>&1 || true)"
  if ! grep -qxF "Version: $pin" <<<"$ver"; then
    # A different oxlint resolves a different rule set, so nothing below would mean anything.
    bad "OXLINT_BIN is the pinned oxlint" "it reports '$ver', ts/pins.json pins oxlint $pin"
  else
    ok "OXLINT_BIN is the pinned oxlint $pin"
    W="$TMP/oxlint"
    mkdir "$W"
    ln -s "$(cd "$(dirname "$OXLINT")/.." && pwd)" "$W/node_modules"
    cp "$KITROOT/ts/oxlint.config.nextjs.ts" "$W/oxlint.config.ts"
    rc=0; (cd "$W" && "$OXLINT" --print-config >"$W/resolved.json" 2>"$W/stderr") || rc=$?
    # oxlint prints severities as deny/warn/allow, a bare level or [level, options].
    python3 - "$W" <<'PY' || rc=1
import json, sys
w = sys.argv[1]
rules = json.load(open(f"{w}/resolved.json"))["rules"]
level = {k: (v[0] if isinstance(v, list) else v) for k, v in rules.items()}
open(f"{w}/error.txt", "w").write("".join(f"{k}\n" for k, v in level.items() if v == "deny"))
open(f"{w}/allow.txt", "w").write("".join(f"{k}\n" for k, v in level.items() if v == "allow"))
PY
    if [ "$rc" != 0 ] || [ ! -s "$W/error.txt" ]; then
      bad "nextjs config resolves" "rc=$rc $(cat "$W/stderr")"
    else
      # oxcheck FILE — one line per oxlint row in FILE whose rule is not at error.
      oxcheck() {
        python3 - "$1" "$W/error.txt" <<'PY'
import json, sys
errors = set(open(sys.argv[2]).read().split())
try:
    rows = json.load(open(sys.argv[1]))
except (OSError, ValueError) as e:
    print(f"coverage.json is unreadable: {e}")
    sys.exit(0)
for k, r in sorted(rows.items()):
    if isinstance(r, dict) and r.get("by") == "oxlint" and r.get("rule") not in errors:
        print(f"{k} names {r.get('rule')}, which the nextjs config does not resolve at error")
PY
      }
      OXROWS="every oxlint row names a rule at error in the resolved nextjs config"
      hits="$(oxcheck "$RULES/coverage.json")"
      if [ -z "$hits" ]; then ok "$OXROWS"; else
        while IFS= read -r h; do bad "$OXROWS" "$h"; done <<<"$hits"
      fi
      off="$(head -n1 "$W/allow.txt")"
      if [ -z "$off" ]; then
        bad "arm: a disabled oxlint rule is caught" "the resolved nextjs config has no disabled rule to probe with"
      else
        fresh; mutate "rows['js-hoist-regexp'] = {'by': 'oxlint', 'rule': '$off', 'static_export': 'applies', 'why': 'x'}"
        grep -qF -- "$off" <<<"$(oxcheck "$T/coverage.json")" \
          && ok "arm: a disabled oxlint rule is caught" || bad "arm: a disabled oxlint rule is caught" "oxcheck did not report $off"
      fi
    fi
  fi
fi

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
