#!/usr/bin/env bash
# What: regression test — the kit's own shipped oxlint.config.*.ts files must
#       already be clean under the kit's own oxlint + ultracite preset (not
#       just under oxfmt formatting — see oxfmt-clean.test.sh for that half),
#       and a stamped repo's lint must not scan the kit's stamped files at all.
#       Where: quality-kit/ts.
# Why:  v0.3.1 shipped `readFileSync(..., "utf8")` in all three configs, which
#       trips unicorn/text-encoding-identifier-case — a rule the fleet's own
#       ultracite preset enables. oxlint.config.ts is a byte-owned stamped
#       file the stamped repo may not edit, and the violation cannot be
#       burn-down'd away either: setting it to "warn" in ruleOverrides makes
#       oxlint silently drop that rule's diagnostics entirely (0 reported),
#       so the drift ratchet then refuses the "complete, remove the entry"
#       state forever — a real deadlock, not just an annoyance. Catch any
#       such violation here, at the source, before it ships.
#       Until v0.7.1 the stamped files were also linted AS repo code: under
#       --type-aware the untyped plugin and the config's two assertions raised
#       80 findings that the stamper seeded into every fresh repo's burnDown.
#       The configs now ignore them, so the cleanliness checks below lint
#       copies under other names, each backed by a positive control.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }

# Needs a real oxlint whose node_modules ALSO has ultracite (the config imports
# ultracite/oxlint/*) — same binary the override integration test uses. CI
# installs the pinned toolchain and sets it; locally, set it to any stamped
# repo's node_modules/.bin/oxlint. Unset (e.g. bare cockpit CI without the
# toolchain step) skips cleanly rather than failing the suite.
OXLINT="${OXLINT_BIN:-}"
if [ -z "$OXLINT" ] || ! command -v node >/dev/null 2>&1; then
  echo "SKIP oxlint cleanliness check (set OXLINT_BIN to an oxlint whose node_modules has ultracite)"
  exit 0
fi
NM="$(cd "$(dirname "$OXLINT")/.." && pwd)"
# Resolve to absolute before the cd below — OXLINT_BIN is documented as
# "node_modules/.bin/oxlint", a relative path, and a bare relative "$OXLINT"
# invoked after `cd "$W"` would look for the binary inside $W instead.
OXLINT="$(cd "$(dirname "$OXLINT")" && pwd)/$(basename "$OXLINT")"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
# A violation that fires WITHOUT --type-aware (func-style), so it is reported
# by the plain oxlint run this toolchain can do — see kit-checkout-ignored.test.sh.
PROBE='const y = () => 2;\nexport function bad() { return y(); }\n'

# Captured with stderr folded in and no swallowed exit status: oxlint exits
# nonzero both for real diagnostics AND for a config it can't load, and a
# load failure must FAIL this test, not read as "zero diagnostics found".
# Usage: lint <dir> <oxlint args...>; sets $out and $rc.
lint() {
  local d="$1"; shift
  rc=0; out="$(cd "$d" && "$OXLINT" -f json "$@" 2>&1)" || rc=$?
}
# Prints "<ran> <total> <stamped> <controls>" for $out. ran=0 means the output
# was not a JSON diagnostics list — likely a config load failure, never zero.
tally() {
  python3 -c "
import json,sys
try:
    diags = json.loads(sys.stdin.read())['diagnostics']
    if not isinstance(diags, list): raise ValueError
except Exception:
    print('0 0 0 0'); sys.exit()
def name(x):
    f = x.get('filename') or ''
    return f[2:] if f.startswith('./') else f
print(1, len(diags),
      len([x for x in diags if name(x) in ('oxlint.config.ts', 'oxlint-react-rules.mjs')]),
      len([x for x in diags if name(x) == 'control.ts']))" <<<"$out"
}

# node.ts doubles as the active oxlint.config.ts for this run (any of the three
# would do — they extend the same core preset); the copies alongside it are
# then linted as plain source files under that config, same as the other two.
# The active copy itself is ignored by its own config; the named copies are not.
configs_dir() {
  mkdir "$1"
  ln -s "$NM" "$1/node_modules"
  cp "$DIR/oxlint.config.node.ts" "$1/oxlint.config.ts"
  cp "$DIR/oxlint.config.nextjs.ts" "$DIR/oxlint.config.vite.ts" "$DIR/oxlint.config.node.ts" "$1/"
}
label="shipped TS configs are oxlint-clean"
configs_dir "$T/configs"
lint "$T/configs" .
read -r ran total _ _ <<<"$(tally)"
if [ "$ran" != 1 ]; then
  bad "$label" "oxlint output was not valid JSON — likely a config load failure: $out"
elif [ "$total" != 0 ]; then
  bad "$label" "$total diagnostic(s): $out"
else
  ok "$label"
fi
# Positive control: the same run with a probe in one config copy must report
# it, or the clean result above is satisfied by a run that linted nothing.
configs_dir "$T/configs-probe"
printf "$PROBE" >> "$T/configs-probe/oxlint.config.vite.ts"
lint "$T/configs-probe" .
read -r ran total _ _ <<<"$(tally)"
if [ "$ran" != 1 ]; then
  bad "$label (positive control)" "oxlint output was not valid JSON — likely a config load failure: $out"
elif [ "$total" -lt 1 ]; then
  bad "$label (positive control)" "a probed config copy reported 0 diagnostics — the clean check proves nothing"
else
  ok "$label (positive control: probed copy reported)"
fi

# The nextjs profile also stamps its React-rules plugin, which every nextjs repo
# then lints as its own source under the nextjs config — the same deadlock as
# above if it carried a single violation. The config ignores the stamped name,
# so the plugin is linted as a copy under another name; the stamped one stays
# beside the config only so jsPlugins can load it.
plugin_dir() {
  mkdir "$1"
  ln -s "$NM" "$1/node_modules"
  cp "$DIR/oxlint.config.nextjs.ts" "$1/oxlint.config.ts"
  cp "$DIR/oxlint-react-rules.mjs" "$1/"
  cp "$DIR/oxlint-react-rules.mjs" "$1/plugin-under-test.mjs"
}
label="shipped lint plugin is oxlint-clean under the nextjs config"
plugin_dir "$T/plugin"
lint "$T/plugin" plugin-under-test.mjs
read -r ran total _ _ <<<"$(tally)"
if [ "$ran" != 1 ]; then
  bad "$label" "oxlint output was not valid JSON — likely a config load failure: $out"
elif [ "$total" != 0 ] || [ "$rc" != 0 ]; then
  bad "$label" "rc=$rc, $total diagnostic(s): $out"
else
  ok "$label"
fi
plugin_dir "$T/plugin-probe"
printf "$PROBE" >> "$T/plugin-probe/plugin-under-test.mjs"
lint "$T/plugin-probe" plugin-under-test.mjs
read -r ran total _ _ <<<"$(tally)"
if [ "$ran" != 1 ]; then
  bad "$label (positive control)" "oxlint output was not valid JSON — likely a config load failure: $out"
elif [ "$total" -lt 1 ]; then
  bad "$label (positive control)" "a probed plugin copy reported 0 diagnostics — the clean check proves nothing"
else
  ok "$label (positive control: probed copy reported)"
fi

# A stamped repo's own lint run must never report the kit's stamped files — with
# or without --type-aware — while still linting repo code. Each stamped file
# carries the probe; control.ts carries it too and must be reported.
for profile in nextjs node vite; do
  S="$T/stamp-$profile"
  mkdir "$S"
  ln -s "$NM" "$S/node_modules"
  cp "$DIR/oxlint.config.$profile.ts" "$S/oxlint.config.ts"
  stamped="oxlint.config.ts"
  if [ "$profile" = nextjs ]; then
    cp "$DIR/oxlint-react-rules.mjs" "$S/"
    stamped="oxlint.config.ts oxlint-react-rules.mjs"
  fi
  printf '{"version":"0.7.1","profile":"%s","runner":"npm","pendingFlags":[],"ruleOverrides":{"burnDown":{},"permanent":{}},"ignoreOverrides":[]}\n' \
    "$profile" > "$S/.quality-kit.json"
  for f in $stamped; do printf "$PROBE" >> "$S/$f"; done
  printf "$PROBE" > "$S/control.ts"

  label="$profile: stamped $stamped excluded from the repo's lint"
  lint "$S" .
  read -r ran _ leaked controls <<<"$(tally)"
  if [ "$ran" != 1 ]; then
    bad "$label" "oxlint did not produce a diagnostics list (exit $rc): $out"
  elif [ "$controls" -lt 1 ]; then
    bad "$label" "positive control was not reported — the linter ran but the probe no longer trips a rule, so the exclusion proves nothing"
  elif [ "$leaked" != 0 ]; then
    bad "$label" "$leaked diagnostic(s) came from the stamped files"
  else
    ok "$label (control reported, stamped files silent)"
  fi
done

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
