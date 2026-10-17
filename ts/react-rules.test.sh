#!/usr/bin/env bash
# What: ts/react-rules/ stays the pinned, never-edited upstream bytes, and
#       coverage.json maps every vendored rule to what enforces it; every
#       `custom` row's kit rule is proved on that rule's own vendored examples.
# Where: quality-kit/ts.
# Why:  the coverage table is only worth reading while it matches the files it
#       describes: a rule added or dropped by a pin bump, an edited vendored
#       byte, an `oxlint` or `custom` row naming a rule the nextjs profile does
#       not enforce at error, or a kit rule that misses its incorrect example or
#       flags its correct one would each make it claim coverage nobody has.
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
EXAMPLES="every custom row has an incorrect and a correct example"
BYTES="vendored bytes match SOURCE.json"

# Example extraction, shared by the checks below. An example is a block fenced
# exactly ```tsx, ```ts or ```typescript whose nearest preceding `**` line starts
# with `**Incorrect` or `**Correct`; anything else (a `**Warning` block, an svg
# fence) is neither. Its bytes are taken as they are, never retyped.
cat >"$TMP/examples.py" <<'PY'
import json, os, sys

def examples(path):
    found = {"incorrect": [], "correct": []}
    label, lang, body = "", None, []
    for line in open(path, encoding="utf-8", newline="").read().splitlines(keepends=True):
        bare = line.rstrip("\r\n")
        if lang is None:
            if bare.startswith("```"):
                lang, body = bare[3:], []
            elif bare.startswith("**"):
                label = bare
        elif bare.strip() == "```":
            kind = next((k for k in found if label.startswith("**" + k.capitalize())), None)
            if kind and lang in ("tsx", "ts", "typescript"):
                found[kind].append(("tsx" if lang == "tsx" else "ts", "".join(body)))
            lang = None
        else:
            body.append(line)
    return found

# examples.py D OUT [ID] — writes each example of D's custom rows (only ID's, when
# given) to its own file under OUT; prints "<id> <kind> <n> <rule> <file>" per file.
if __name__ == "__main__":
    d, out, only = sys.argv[1], sys.argv[2], sys.argv[3:]
    for k, r in sorted(json.load(open(os.path.join(d, "coverage.json"))).items()):
        if r.get("by") != "custom" or (only and k not in only):
            continue
        for sub in ("best-practices", "composition"):
            md = os.path.join(d, sub, k + ".md")
            if not os.path.isfile(md):
                continue
            for kind, found in examples(md).items():
                for n, (ext, code) in enumerate(found, 1):
                    p = os.path.join(out, k, f"{kind}-{n}.{ext}")
                    os.makedirs(os.path.dirname(p), exist_ok=True)
                    open(p, "w", encoding="utf-8", newline="").write(code)
                    print(k, kind, n, r["rule"], p)
PY

# check D — prints one "<label>|<detail>" line per problem in the react-rules
# tree at D; prints nothing when it is clean. Rule ids are the stems of the
# non-`_` *.md files in best-practices/ and composition/, plus one id for the
# single web-interface-guidelines.md file.
check() {
  local d="$1"
  python3 - "$d" "$ROWS" "$VALUES" "$EXAMPLES" "$TMP" <<'PY'
import json, os, sys
d, ROWS, VALUES, EXAMPLES, tmp = sys.argv[1:]
sys.path.insert(0, tmp)
from examples import examples
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
    if r["by"] in ("oxlint", "custom"):
        if not isinstance(r["rule"], str) or not r["rule"].strip():
            print(f"{VALUES}|{k} is by {r['by']} but names no rule")
        elif r["by"] == "custom" and r["rule"].split("/")[-1] != k:
            print(f"{VALUES}|{k} is by custom but its rule {r['rule']!r} is not named after it")
    elif r["rule"] is not None:
        print(f"{VALUES}|{k} is by {r['by']} but its rule is {r['rule']!r}, want null")
    # The phrase every pre-0.7.0 `custom` why opened with: a row moved to review
    # still saying it is the stale reason, not a new one.
    if r["by"] == "review" and "A machine can flag" in str(r["why"]):
        print(f"{VALUES}|{k} is by review but its why still says a machine can flag it")
    if r["by"] == "custom" and k in want:
        found = examples(os.path.join(d, want[k]))
        for kind in ("incorrect", "correct"):
            if not found[kind]:
                print(f"{EXAMPLES}|{k} is by custom but {want[k]} has no {kind} tsx/ts/typescript example")
for k in ("server-auth-actions", "async-api-routes"):
    r = rows.get(k)
    if isinstance(r, dict) and r.get("static_export") != "n/a":
        print(f"{VALUES}|{k} is server-only, so static_export must be n/a")
for k, r in sorted(rows.items()):
    client = k.startswith(("rerender-", "client-")) or want.get(k, "").startswith("composition/")
    if client and isinstance(r, dict) and r.get("static_export") != "applies":
        print(f"{VALUES}|{k} runs in a static export, so static_export must be applies")
# Plainly decidable from one file's syntax, and each has a kit rule.
for k in ("async-parallel", "client-passive-event-listeners", "js-flatmap-filter",
          "rerender-lazy-state-init", "react19-no-forwardref"):
    r = rows.get(k)
    if isinstance(r, dict) and r.get("by") != "custom":
        print(f"{VALUES}|{k} is decidable by a kit rule, so it must stay by custom")
w = rows.get("web-interface-guidelines")
if isinstance(w, dict):
    if w.get("by") != "review" or w.get("rule") is not None:
        print(f"{VALUES}|web-interface-guidelines must be by review with a null rule")
    why = str(w.get("why", "")).lower()
    for s in ("keyboard", "autocomplete", "picture"):
        if s not in why:
            print(f"{VALUES}|web-interface-guidelines why must mention {s}")
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
for label in "$ROWS" "$VALUES" "$EXAMPLES" "$BYTES"; do report "$label" "$out"; done

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
fresh; printf 'x' >>"$T/best-practices/_sections.md"
caught "an edited scaffolding byte is caught" "best-practices/_sections.md"
fresh; mutate 'rows["js-hoist-regexp"]["by"] = "oxlnt"'
caught "an invalid by is caught" "js-hoist-regexp"
fresh; mutate 'rows["async-parallel"]["rule"] = None'
caught "a custom row with a null rule is caught" "async-parallel"

pin="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["oxlint"])' "$KITROOT/ts/pins.json")"
# version_guard BIN — FAIL unless BIN reports the pinned oxlint version.
version_guard() {
  local ver
  ver="$("$1" --version 2>&1 || true)"
  if ! grep -qxF "Version: $pin" <<<"$ver"; then
    # A different oxlint resolves a different rule set, so nothing after this would mean anything.
    bad "OXLINT_BIN is the pinned oxlint" "it reports '$ver', ts/pins.json pins oxlint $pin"
    return 1
  fi
  ok "OXLINT_BIN is the pinned oxlint $pin"
}
printf '#!/usr/bin/env bash\necho "Version: 1.0.0"\n' >"$TMP/fake-oxlint"
chmod +x "$TMP/fake-oxlint"
rc=0; got="$(version_guard "$TMP/fake-oxlint")" || rc=$?
if [ "$rc" != 0 ] && grep -q "^FAIL .*$pin" <<<"$got"; then ok "arm: a wrong oxlint version is refused"
else bad "arm: a wrong oxlint version is refused" "rc=$rc out=$got"; fi

# Every `oxlint` and `custom` row must name a rule the nextjs profile resolves at
# error, read from the pinned oxlint's own output for the shipped config — never
# from a hand-written list — and every custom rule must fail each of its incorrect
# examples and pass each correct one. Needs an oxlint whose node_modules also has
# ultracite (the config imports ultracite/oxlint/*); unset OXLINT_BIN skips, as in
# oxlint-overrides.test.sh.
OXLINT="${OXLINT_BIN:-}"
if [ -z "$OXLINT" ]; then
  echo "SKIP oxlint severity check (set OXLINT_BIN to the pinned oxlint whose node_modules has ultracite)"
  echo "SKIP custom rule fixtures (set OXLINT_BIN to the pinned oxlint whose node_modules has ultracite)"
elif version_guard "$OXLINT"; then
  # Absolute, because every run below happens after a cd and OXLINT_BIN may be relative.
  OXLINT="$(cd "$(dirname "$OXLINT")" && pwd)/$(basename "$OXLINT")"
  NM="$(cd "$(dirname "$OXLINT")/.." && pwd)"
  # The shipped config and its plugin, at the paths bin/stamp.sh writes them to.
  W="$TMP/oxlint"
  mkdir "$W"
  ln -s "$NM" "$W/node_modules"
  cp "$KITROOT/ts/oxlint.config.nextjs.ts" "$W/oxlint.config.ts"
  cp "$KITROOT/ts/oxlint-react-rules.mjs" "$W/oxlint-react-rules.mjs"
  python3 "$TMP/examples.py" "$RULES" "$W/fx" >"$W/fx.list"
  rc=0; (cd "$W" && "$OXLINT" --print-config >"$W/resolved.json" 2>"$W/stderr") || rc=$?
  # oxlint 1.74.0's --print-config leaves jsPlugins rules out of `rules` (measured),
  # so their level comes from oxlint itself linting every extracted incorrect
  # example under the full shipped config: a plugin rule is at error when oxlint
  # reports it with severity error. It prints a rule as plugin(rule); the config
  # names it plugin/rule.
  (cd "$W" && "$OXLINT" -f json fx >"$W/examples.json" 2>>"$W/stderr") || true
  # oxlint prints severities as deny/warn/allow, a bare level or [level, options].
  python3 - "$W" <<'PY' || rc=1
import json, re, sys
w = sys.argv[1]
rules = json.load(open(f"{w}/resolved.json"))["rules"]
level = {k: (v[0] if isinstance(v, list) else v) for k, v in rules.items()}
for d in json.load(open(f"{w}/examples.json"))["diagnostics"]:
    m = re.fullmatch(r"(.+)\((.+)\)", d.get("code") or "")
    if m and d.get("severity") == "error":
        level[f"{m[1]}/{m[2]}"] = "deny"
open(f"{w}/error.txt", "w").write("".join(f"{k}\n" for k, v in level.items() if v == "deny"))
open(f"{w}/allow.txt", "w").write("".join(f"{k}\n" for k, v in level.items() if v == "allow"))
PY
  if [ "$rc" != 0 ] || [ ! -s "$W/error.txt" ]; then
    bad "nextjs config resolves" "rc=$rc $(cat "$W/stderr")"
  else
    # oxcheck BY FILE — one line per BY row in FILE whose rule is not at error.
    oxcheck() {
      python3 - "$1" "$2" "$W/error.txt" <<'PY'
import json, sys
by, path = sys.argv[1:3]
errors = set(open(sys.argv[3]).read().split())
try:
    rows = json.load(open(path))
except (OSError, ValueError) as e:
    print(f"coverage.json is unreadable: {e}")
    sys.exit(0)
for k, r in sorted(rows.items()):
    if isinstance(r, dict) and r.get("by") == by and r.get("rule") not in errors:
        print(f"{k} names {r.get('rule')}, which the nextjs config does not resolve at error")
PY
    }
    for by in oxlint custom; do
      label="every $by row names a rule at error in the resolved nextjs config"
      hits="$(oxcheck "$by" "$RULES/coverage.json")"
      if [ -z "$hits" ]; then ok "$label"; else
        while IFS= read -r h; do bad "$label" "$h"; done <<<"$hits"
      fi
    done
    off="$(head -n1 "$W/allow.txt")"
    if [ -z "$off" ]; then
      bad "arm: a disabled oxlint rule is caught" "the resolved nextjs config has no disabled rule to probe with"
    else
      fresh; mutate "rows['js-hoist-regexp'] = {'by': 'oxlint', 'rule': '$off', 'static_export': 'applies', 'why': 'x'}"
      grep -qF -- "$off" <<<"$(oxcheck oxlint "$T/coverage.json")" \
        && ok "arm: a disabled oxlint rule is caught" || bad "arm: a disabled oxlint rule is caught" "oxcheck did not report $off"
      fresh; mutate "rows['react19-no-forwardref']['rule'] = '$off'"
      grep -qF -- "$off" <<<"$(oxcheck custom "$T/coverage.json")" \
        && ok "arm: a custom row naming a rule not at error is caught" \
        || bad "arm: a custom row naming a rule not at error is caught" "oxcheck did not report $off"
    fi
  fi

  # fixtures LIST — lints each example file in LIST (examples.py's output) on its
  # own, with the shipped plugin and only its row's rule on, and prints
  # "ok|fixture: <id> <kind> <n>" or "bad|fixture: <id> <kind> <n>|<why>".
  # The rule runs at error, the level the check above holds the shipped config
  # to. Not `-A all -D <rule>` on the shipped config: that leaves the config's
  # other jsPlugins rules on (measured, oxlint 1.74.0). An incorrect example
  # passes only on a non-zero exit WITH its rule in the output, so one that merely
  # fails to parse is not counted as the rule firing. "on 1 file with 1 rules" is
  # oxlint's own summary: the file was linted and nothing but the rule ran. Any
  # agent variable switches oxlint to a compact format with no summary line
  # (measured, oxlint 1.74.0), so the lint runs with all of them unset.
  fixtures() {
    local id kind num rule file rc out
    while read -r id kind num rule file; do
      python3 - "$rule" >"$W/only.json" <<'PY'
import json, sys
print(json.dumps({"jsPlugins": ["./oxlint-react-rules.mjs"], "plugins": [],
                  "categories": {"correctness": "off"}, "rules": {sys.argv[1]: "error"}}))
PY
      rc=0; out="$(cd "$W" && env -u AI_AGENT -u CLAUDECODE -u CLAUDE_CODE -u CODEX_SANDBOX \
        -u CODEX_THREAD_ID -u GEMINI_CLI -u CURSOR_AGENT "$OXLINT" -c only.json "$file" 2>&1)" || rc=$?
      if ! grep -qF "on 1 file with 1 rules" <<<"$out"; then
        echo "bad|fixture: $id $kind $num|oxlint did not lint the file with $rule alone (rc=$rc): ${out//$'\n'/ }"
      elif [ "$kind" = incorrect ] && { [ "$rc" = 0 ] || ! grep -qF -- "$rule" <<<"$out"; }; then
        echo "bad|fixture: $id $kind $num|want a non-zero exit with a $rule diagnostic, got rc=$rc: ${out//$'\n'/ }"
      elif [ "$kind" = correct ] && { [ "$rc" != 0 ] || grep -qF -- "$rule" <<<"$out"; }; then
        echo "bad|fixture: $id $kind $num|want a zero exit with no $rule diagnostic, got rc=$rc: ${out//$'\n'/ }"
      else
        echo "ok|fixture: $id $kind $num"
      fi
    done <"$1"
  }
  while IFS='|' read -r st label detail; do
    if [ "$st" = ok ]; then ok "$label"; else bad "$label" "$detail"; fi
  done < <(fixtures "$W/fx.list")

  # CI runs without agent variables, so this row sets them all and runs the same
  # fixture check: every js-flatmap-filter row must still pass.
  AGENT="fixture lint ignores an agent environment"
  python3 "$TMP/examples.py" "$RULES" "$W/fx-agent" js-flatmap-filter >"$W/fx-agent.list"
  got="$(export AI_AGENT=1 CLAUDECODE=1 CLAUDE_CODE=1 CODEX_SANDBOX=1 CODEX_THREAD_ID=1 GEMINI_CLI=1 CURSOR_AGENT=1
    fixtures "$W/fx-agent.list")"
  if [ -n "$got" ] && ! grep -qv '^ok|' <<<"$got"; then ok "$AGENT"; else bad "$AGENT" "${got//$'\n'/ }"; fi

  # fixture_arm LABEL PY — on a fresh copy, PY rewrites `text`, the copy of
  # best-practices/js-flatmap-filter.md, given its extracted examples `ex`; the
  # fixtures on the copy must then report js-flatmap-filter.
  fixture_arm() {
    fresh
    python3 - "$TMP" "$T/best-practices/js-flatmap-filter.md" "$2" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
from examples import examples
path, stmt = sys.argv[2:]
ex = examples(path)
text = open(path, encoding="utf-8", newline="").read()
exec(stmt)
open(path, "w", encoding="utf-8", newline="").write(text)
PY
    python3 "$TMP/examples.py" "$T" "$W/fx-arm$n" js-flatmap-filter >"$T.list"
    local got; got="$(fixtures "$T.list")"
    grep -q '^bad|fixture: js-flatmap-filter ' <<<"$got" && ok "arm: $1" || bad "arm: $1" "fixtures did not report js-flatmap-filter: $got"
  }
  fixture_arm "an incorrect example that only fails to parse is caught" \
    'text = text.replace(ex["incorrect"][0][1], "const = ;\n", 1)'
  fixture_arm "a flagged correct example is caught" \
    'text = text.replace(ex["correct"][0][1], ex["incorrect"][0][1], 1)'

  # A repo stamped with --profile nextjs, its node_modules the pinned toolchain,
  # must fail its own `lint` script on a custom rule's incorrect example.
  # ponytail: --type-aware is dropped, as in check-drift.test.sh's real-oxlint
  # shim — the kit toolchain carries no oxlint-tsgolint and the kit rules need no
  # types; add tsgolint to ci/oxlint-toolchain to run the script verbatim.
  STAMPED="a stamped nextjs repo's lint fails on react19-no-forwardref incorrect 1"
  C="$TMP/consumer"
  mkdir "$C"
  (cd "$C" && git init -q && git config core.hooksPath /dev/null \
    && git -c user.name=test -c user.email=test@test.local commit -q --allow-empty -m init)
  if bash "$KITROOT/bin/stamp.sh" "$C" --profile nextjs >"$TMP/stamp.log" 2>&1; then
    ln -s "$NM" "$C/node_modules"
    rule="" file=""
    read -r _ _ _ rule file < <(python3 "$TMP/examples.py" "$RULES" "$C/fx" react19-no-forwardref | grep '^react19-no-forwardref incorrect 1 ') || true
    lint="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["scripts"]["lint"])' "$C/package.json")"
    rc=0; out="$(cd "$C" && PATH="$C/node_modules/.bin:$PATH" bash -c "${lint//--type-aware/} \"\$1\"" _ "$file" 2>&1)" || rc=$?
    [ -n "$rule" ] && [ "$rc" != 0 ] && grep -qF -- "$rule" <<<"$out" && ok "$STAMPED" || bad "$STAMPED" "rc=$rc, want non-zero with $rule: $out"
  else
    bad "$STAMPED" "stamp.sh failed: $(cat "$TMP/stamp.log")"
  fi
fi

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
