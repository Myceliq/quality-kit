#!/usr/bin/env bash
# What: regression test — the kit's own shipped oxlint.config.*.ts files must
#       already be clean under the kit's own oxlint + ultracite preset (not
#       just under oxfmt formatting — see oxfmt-clean.test.sh for that half).
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

W="$(mktemp -d)"
ln -s "$NM" "$W/node_modules"
mkdir -p "$W/.quality"
cp "$DIR/agent-legibility.ts" "$W/.quality/agent-legibility.ts"
# node.ts doubles as the active oxlint.config.ts for this run (any of the three
# would do — they extend the same core preset); the copies alongside it are
# then linted as plain source files under that config, same as the other two.
cp "$DIR/oxlint.config.node.ts" "$W/oxlint.config.ts"
cp "$DIR/oxlint.config.nextjs.ts" "$DIR/oxlint.config.vite.ts" "$DIR/oxlint.config.node.ts" "$W/"

# Captured with stderr folded in and no swallowed exit status: oxlint exits
# nonzero both for real diagnostics AND for a config it can't load, and a
# load failure must FAIL this test, not read as "zero diagnostics found".
out="$(cd "$W" && "$OXLINT" -f json . 2>&1)" || true
if [ -z "$out" ]; then
  bad "shipped TS configs are oxlint-clean" "oxlint produced no output at all"
elif n="$(python3 -c "
import json,sys
print(len(json.loads(sys.stdin.read())['diagnostics']))" <<<"$out" 2>/dev/null)"; then
  [ "$n" = 0 ] && ok "shipped TS configs are oxlint-clean" || bad "shipped TS configs are oxlint-clean" "$n diagnostic(s): $out"
else
  bad "shipped TS configs are oxlint-clean" "oxlint output was not valid JSON — likely a config load failure: $out"
fi

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
