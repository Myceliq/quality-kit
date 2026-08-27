#!/usr/bin/env bash
# What: integration test — the stamped oxlint config self-applies the repo's
#       declared rule overrides. Where: quality-kit/ts.
# Why:  this is the whole TS override mechanism; if the config stops reading
#       .quality-kit.json the gate silently reverts to fleet-only rules.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
KITROOT="$(cd "$DIR/.." && pwd)"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }

# Needs a real oxlint whose node_modules ALSO has ultracite (the config imports
# ultracite/oxlint/*). Point OXLINT_BIN at it — CI installs the pinned toolchain
# and sets it; locally, set it to any stamped repo's node_modules/.bin/oxlint.
# No machine-specific path here: unset OXLINT_BIN (e.g. a consumer CI without
# the toolchain step) skips cleanly rather than failing the suite.
OXLINT="${OXLINT_BIN:-}"
if [ -z "$OXLINT" ] || ! command -v node >/dev/null 2>&1; then
  echo "SKIP oxlint override integration (set OXLINT_BIN to an oxlint whose node_modules has ultracite)"
  exit 0
fi
NM="$(cd "$(dirname "$OXLINT")/.." && pwd)"   # the node_modules that has ultracite

W="$(mktemp -d)"
ln -s "$NM" "$W/node_modules"
mkdir -p "$W/.quality"
cp "$KITROOT/ts/agent-legibility.ts" "$W/.quality/agent-legibility.ts"
cp "$KITROOT/ts/oxlint.config.node.ts" "$W/oxlint.config.ts"
# func-style is the sole rule this probe trips; the burn-down/permanent cases
# drive that one rule. (An anonymous function expression here would also trip
# func-names — an unrelated hard error no override touches — so keep the probe
# to a single declaration.)
printf 'const y = () => 2;\nexport function bad() { return y(); }\n' > "$W/probe.ts"

# burn-down rule must come back as a WARNING (visible, non-fatal), not an error
cat > "$W/.quality-kit.json" <<'JSON'
{"version":"0.2.0","profile":"node","runner":"npm","pendingFlags":[],
 "ruleOverrides":{"burnDown":{"func-style":5},"permanent":{}},"ignoreOverrides":[]}
JSON
out="$(cd "$W" && "$OXLINT" -f json probe.ts 2>/dev/null || true)"
sev="$(python3 -c "
import json,sys
d=json.loads(sys.stdin.read() or '{\"diagnostics\":[]}')
print(','.join(sorted({x['severity'] for x in d['diagnostics'] if x['code']=='eslint(func-style)'})) or 'none')" <<<"$out")"
[ "$sev" = "warning" ] && ok "burnDown rule downgraded to warning" || bad "burnDown rule downgraded to warning" "severity=$sev"

# and the process must still exit 0 — burn-down is visible, not blocking
rc=0; (cd "$W" && "$OXLINT" probe.ts >/dev/null 2>&1) || rc=$?
[ "$rc" = 0 ] && ok "burnDown does not fail the lint run" || bad "burnDown does not fail the lint run" "rc=$rc"

# Agent-legibility limits are configured in SLOC where Oxlint supports it.
# These probes sit exactly one unit over each fleet ceiling; changing a key,
# rule id, comparison, or severity makes at least one positive control vanish.
{
  printf 'export function complex(value: number) {\n'
  for i in $(seq 1 10); do printf '  if (value === %s) return %s;\n' "$i" "$i"; done
  printf '  return 0;\n}\n'
} > "$W/shape-complexity.ts"
{
  printf 'export function deep(value: boolean) {\n'
  printf '  if (value) { if (value) { if (value) { if (value) { return 1; } } } }\n'
  printf '  return 0;\n}\n'
} > "$W/shape-depth.ts"
{
  printf 'export function longFunction() {\n'
  for _ in $(seq 1 79); do printf '  work();\n'; done
  printf '}\n'
} > "$W/shape-function.ts"
{
  for i in $(seq 1 501); do printf 'export const line%s = %s;\n' "$i" "$i"; done
} > "$W/shape-file.ts"

cat > "$W/.quality-kit.json" <<'JSON'
{"version":"0.2.0","profile":"node","runner":"npm","pendingFlags":[],
 "ruleOverrides":{"burnDown":{},"permanent":{}},"ignoreOverrides":[]}
JSON
shape_out="$(cd "$W" && "$OXLINT" -f json shape-*.ts 2>/dev/null || true)"
python3 -c "
import json,sys
d=json.loads(sys.stdin.read())['diagnostics']
codes={x['code'] for x in d}
want={'eslint(complexity)','eslint(max-depth)','eslint(max-lines)','eslint(max-lines-per-function)'}
assert want <= codes, (want-codes, codes)
assert all(x['severity']=='error' for x in d if x['code'] in want), d
" <<<"$shape_out" \
  && ok "agent-legibility ceilings report all four rules as errors" \
  || bad "agent-legibility ceilings report all four rules as errors" "$shape_out"

# A burn-down severity override must retain the fleet's max=10 option. If the
# config emits bare `warn`, Oxlint falls back to its upstream max=20 and this
# 11-complexity probe disappears instead of remaining visible and ratchetable.
cat > "$W/.quality-kit.json" <<'JSON'
{"version":"0.2.0","profile":"node","runner":"npm","pendingFlags":[],
 "ruleOverrides":{"burnDown":{"complexity":1},"permanent":{}},"ignoreOverrides":[]}
JSON
out="$(cd "$W" && "$OXLINT" -f json shape-complexity.ts 2>/dev/null || true)"
sev="$(python3 -c "
import json,sys
d=json.loads(sys.stdin.read())
print(','.join(x['severity'] for x in d['diagnostics'] if x['code']=='eslint(complexity)') or 'none')" <<<"$out")"
[ "$sev" = "warning" ] && ok "shape burn-down preserves max=10 and becomes warning" || bad "shape burn-down preserves max=10 and becomes warning" "severity=$sev output=$out"

# permanent off must silence the rule entirely
cat > "$W/.quality-kit.json" <<'JSON'
{"version":"0.2.0","profile":"node","runner":"npm","pendingFlags":[],
 "ruleOverrides":{"burnDown":{},"permanent":{"func-style":{"level":"off","why":"legacy module style"}}},
 "ignoreOverrides":[]}
JSON
out="$(cd "$W" && "$OXLINT" -f json probe.ts 2>/dev/null || true)"
n="$(python3 -c "
import json,sys
d=json.loads(sys.stdin.read() or '{\"diagnostics\":[]}')
print(sum(1 for x in d['diagnostics'] if x['code']=='eslint(func-style)'))" <<<"$out")"
[ "$n" = 0 ] && ok "permanent off silences the rule" || bad "permanent off silences the rule" "count=$n"

# ignoreOverrides must drop the file from the run entirely
cat > "$W/.quality-kit.json" <<'JSON'
{"version":"0.2.0","profile":"node","runner":"npm","pendingFlags":[],
 "ruleOverrides":{"burnDown":{},"permanent":{}},"ignoreOverrides":["probe.ts"]}
JSON
out="$(cd "$W" && "$OXLINT" -f json . 2>/dev/null || true)"
n="$(python3 -c "
import json,sys
d=json.loads(sys.stdin.read() or '{\"diagnostics\":[]}')
print(sum(1 for x in d['diagnostics'] if x['filename'].endswith('probe.ts')))" <<<"$out")"
[ "$n" = 0 ] && ok "ignoreOverrides excludes the path" || bad "ignoreOverrides excludes the path" "count=$n"

# with NO .quality-kit.json sibling (unstamped / partial-stamp context) the config
# must still LOAD and lint, falling back to fleet rules — not throw at config load.
# A reintroduced unconditional read makes oxlint print "Failed to load config"
# (ENOENT) instead of JSON diagnostics, so the tolerant parse below flags it.
rm -f "$W/.quality-kit.json"
out="$(cd "$W" && "$OXLINT" -f json probe.ts 2>/dev/null || true)"
n="$(python3 -c "
import json,sys
try:
    d=json.loads(sys.stdin.read() or '{\"diagnostics\":[]}')
except ValueError:
    print('CONFIG_LOAD_ERROR'); sys.exit(0)
print(sum(1 for x in d['diagnostics'] if x['code']=='eslint(func-style)'))" <<<"$out")"
[ "$n" = 1 ] && ok "missing .quality-kit.json falls back, config still loads" || bad "missing .quality-kit.json falls back, config still loads" "n=$n"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
