#!/usr/bin/env bash
# What: integration test — quality-kit/no-use-effect flags a raw useEffect outside
#       an effects/ directory and leaves the byte-identical file inside one alone,
#       and the shipped nextjs config runs it at error, at warn once burnDown
#       ledgers it. Where: quality-kit/ts.
# Why:  the exemption is a path test, so the only proof is the same bytes linted
#       at both paths; the armed control (the rule off, exit 0) shows the failure
#       is the rule's own, not another diagnostic or a config that failed to load.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
KITROOT="$(cd "$DIR/.." && pwd)"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }

# Same contract as oxlint-overrides.test.sh: an oxlint whose node_modules also has
# ultracite (the shipped config imports ultracite/oxlint/*); unset skips cleanly.
OXLINT="${OXLINT_BIN:-}"
if [ -z "$OXLINT" ] || ! command -v node >/dev/null 2>&1; then
  echo "SKIP no-use-effect integration (set OXLINT_BIN to an oxlint whose node_modules has ultracite)"
  exit 0
fi
NM="$(cd "$(dirname "$OXLINT")/.." && pwd)"
# Absolute, because every run below happens after a cd and OXLINT_BIN may be relative.
OXLINT="$(cd "$(dirname "$OXLINT")" && pwd)/$(basename "$OXLINT")"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
# The fixture root itself sits under a directory named `effects`: a rule that
# matched the absolute path instead of the path below the lint root would exempt
# both files, and the src/app case below would fail.
W="$T/effects/repo"
mkdir -p "$W/src/app" "$W/src/effects"
ln -s "$NM" "$W/node_modules"
cp "$KITROOT/ts/oxlint-react-rules.mjs" "$W/"
printf 'import { useEffect } from "react";\nexport function C() { useEffect(() => {}, []); return null; }\n' \
  | tee "$W/src/app/c.tsx" >"$W/src/effects/c.tsx"
# The other banned hook, through the React.-qualified callee.
printf 'import * as React from "react";\nexport function L() { React.useLayoutEffect(() => {}, []); return null; }\n' \
  >"$W/src/app/l.tsx"
# An aliased named import, a namespace not called React and a spelled-out default
# import: three diagnostics.
printf 'import { useEffect as useMount } from "react";\nimport * as R from "react";\nimport { default as D } from "react";\nexport function A() { useMount(() => {}, []); R.useEffect(() => {}, []); D.useLayoutEffect(() => {}, []); return null; }\n' \
  >"$W/src/app/a.tsx"

# only LEVEL [DIR TARGET] — run the kit plugin with no-use-effect at LEVEL and no
# other rule, from DIR (default the fixture root) over TARGET (default src); sets
# $out and $rc. "on N file(s)" is oxlint's own summary (explicit default format
# keeps it under agent detection): every file was linted, so a clean
# src/effects/c.tsx is the exemption, not a file that never ran.
only() {
  printf '{"jsPlugins":["./oxlint-react-rules.mjs"],"plugins":[],"categories":{"correctness":"off"},"rules":{"quality-kit/no-use-effect":"%s"}}\n' "$1" >"$W/only.json"
  rc=0; out="$(cd "${2:-$W}" && "$OXLINT" --format default -c "$W/only.json" "${3:-src}" 2>&1)" || rc=$?
}

only error
L="no-use-effect flags src/app/c.tsx and exempts the identical src/effects/c.tsx"
if [ "$rc" != 0 ] && grep -qF "on 4 files" <<<"$out" && grep -qF "src/app/c.tsx" <<<"$out" \
  && grep -qF "quality-kit/no-use-effect" <<<"$out" && ! grep -qF "src/effects/c.tsx" <<<"$out"; then
  ok "$L"
else
  bad "$L" "rc=$rc ${out//$'\n'/ }"
fi
L="no-use-effect flags React.useLayoutEffect and names that hook"
if grep -qF "src/app/l.tsx" <<<"$out" && grep -qF "useLayoutEffect is off-limits" <<<"$out"; then
  ok "$L"
else
  bad "$L" "rc=$rc ${out//$'\n'/ }"
fi
L="no-use-effect flags an aliased import, a non-React namespace and { default as D }"
n="$(grep -cF "[src/app/a.tsx:" <<<"$out" || true)"
[ "$n" = 3 ] && ok "$L" || bad "$L" "want 3 diagnostics in src/app/a.tsx, got $n: ${out//$'\n'/ }"

# The exemption is anchored to the plugin's own directory, the repo root, not to
# the directory oxlint runs from: from inside src/effects the file keeps its
# effects/ segment, and from $T, where every path starts effects/repo/, src/app is
# still checked.
only error "$W/src/effects" .
L="run from src/effects, the effects/ file stays exempt"
if [ "$rc" = 0 ] && grep -qF "on 1 file" <<<"$out"; then ok "$L"; else bad "$L" "rc=$rc ${out//$'\n'/ }"; fi
only error "$T" effects/repo/src
L="run from the directory above an effects/ checkout, src/app is still checked"
if [ "$rc" != 0 ] && grep -qF "on 4 files" <<<"$out" && grep -qF "effects/repo/src/app/c.tsx" <<<"$out" \
  && ! grep -qF "src/effects/c.tsx" <<<"$out"; then
  ok "$L"
else
  bad "$L" "rc=$rc ${out//$'\n'/ }"
fi

only off
L="armed control: with no-use-effect off the same run exits 0"
if [ "$rc" = 0 ] && grep -qF "on 4 files" <<<"$out"; then ok "$L"; else bad "$L" "rc=$rc ${out//$'\n'/ }"; fi

# The shipped nextjs config runs the rule at error, and a burnDown entry for it
# downgrades it to warn, as bump-pin.sh's seeding relies on.
cp "$KITROOT/ts/oxlint.config.nextjs.ts" "$W/oxlint.config.ts"
for burn in '{"quality-kit/no-use-effect":1}|warning' '{}|error'; do
  printf '{"version":"0.7.1","profile":"nextjs","runner":"npm","pendingFlags":[],"ruleOverrides":{"burnDown":%s,"permanent":{}},"ignoreOverrides":[]}\n' \
    "${burn%|*}" >"$W/.quality-kit.json"
  out="$(cd "$W" && "$OXLINT" -f json src/app/c.tsx 2>/dev/null || true)"
  sev="$(python3 -c "
import json,sys
d=json.loads(sys.stdin.read() or '{\"diagnostics\":[]}')
print(','.join(sorted({x['severity'] for x in d['diagnostics'] if x['code']=='quality-kit(no-use-effect)'})) or 'none')" <<<"$out")"
  [ "$sev" = "${burn#*|}" ] && ok "nextjs no-use-effect with burnDown ${burn%|*} reports at ${burn#*|}" \
    || bad "nextjs no-use-effect with burnDown ${burn%|*} reports at ${burn#*|}" "severity=$sev"
done

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
