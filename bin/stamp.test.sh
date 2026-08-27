#!/usr/bin/env bash
# What: behavior tests for stamp.sh. Where: quality-kit/bin.
# Why:  the stamper is the fleet's write path — idempotency and merge
#       correctness decide whether re-stamps are safe PRs or repo damage.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
S="$DIR/stamp.sh"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }

mk_ts_repo() {
  local r; r="$(mktemp -d)"
  (cd "$r" && git init -q && git config core.hooksPath /dev/null && printf '{"name":"fix","scripts":{"dev":"next dev","build":"next build"},"devDependencies":{"typescript":"^5"}}' > package.json \
    && printf '{"compilerOptions":{"jsx":"preserve"}}' > tsconfig.json \
    && printf '# Fixture\nrepo docs\n' > AGENTS.md \
    && printf '// @ts-ignore\nexport const a=1;\n' > legacy.ts \
    && git add -A && git -c user.name=test -c user.email=test@test.local commit -q -m init)
  echo "$r"
}

R="$(mk_ts_repo)"
first_out="$(bash "$S" "$R" --profile nextjs 2>&1)"
echo "$first_out"

for f in .quality/format-changed.sh .quality/stop-validate.sh .quality/agent-legibility.ts .quality/suppression-baseline.json \
         .quality/manifest.sha256 .quality-kit.json oxlint.config.ts oxfmt.config.ts \
         tsconfig.quality.json .github/workflows/quality.yml .codex/hooks.json .claude/settings.json; do
  [ -f "$R/$f" ] && ok "stamped $f" || bad "stamped $f" "missing"
done

# stamping .codex/hooks.json does not arm it — Codex skips a project's hooks
# unless the project is trusted AND the hook approved, both silently. Losing
# this line is how the kit goes back to shipping a gate nobody knows is off.
# Assert BOTH gates and the config boundary: a grep on the first clause alone
# stays green while the warning silently loses the second activation condition,
# which is the one nobody performs.
echo "$first_out" | grep -q "INERT until Codex trusts this project AND the hooks are approved once" \
  && ok "stamp names both Codex trust gates" \
  || bad "stamp names both Codex trust gates" "$first_out"
echo "$first_out" | grep -Fq 'does not read or write $CODEX_HOME/config.toml, default ~/.codex' \
  && ok "stamp states the kit does not grant trust itself" \
  || bad "stamp states the kit does not grant trust itself" "$first_out"

python3 -c "
import json
qk=json.load(open('$R/.quality-kit.json'))
kit_version=open('$DIR/../VERSION').read().strip()
assert qk=={'version':kit_version,'profile':'nextjs','runner':'npm','pendingFlags':[],
            'ruleOverrides':{'burnDown':{},'permanent':{}},'ignoreOverrides':[]}, qk
p=json.load(open('$R/package.json'))
assert p['scripts']['dev']=='next dev', 'existing scripts preserved'
assert 'validate' in p['scripts'] and 'validate:fast' in p['scripts']
assert p['devDependencies']['oxlint']=='1.74.0' and p['devDependencies']['typescript']=='7.0.2'
# the stamper writes the Node floor its own drift gate enforces — a fresh stamp
# must never be red on the kit's own new gate
assert p['engines']['node']==json.load(open('$DIR/../ts/engines.json'))['node'], p.get('engines')
base=json.load(open('$R/.quality/suppression-baseline.json'))
assert base['ts-ignore']==1, base   # counted from legacy.ts, not zeroed
ts=json.load(open('$R/tsconfig.json'))
assert ts['extends']=='./tsconfig.quality.json'
" && ok "merges + baseline + tsconfig extends" || bad "merges + baseline + tsconfig extends" "assertion failed"

grep -q 'quality-kit:begin' "$R/AGENTS.md" && grep -q '# Fixture' "$R/AGENTS.md" \
  && ok "AGENTS.md section appended, original kept" || bad "AGENTS.md section" "marker or original missing"

# tsconfig extends chain: pre-existing extends preserved, not clobbered
# (TS 5+ array form, quality fragment appended last so its strict flags govern)
E="$(mktemp -d)"
(cd "$E" && git init -q && git config core.hooksPath /dev/null \
  && printf '{"extends":"@base/x","compilerOptions":{}}' > tsconfig.json \
  && git add -A && git -c user.name=test -c user.email=test@test.local commit -q -m init)
bash "$S" "$E" --profile nextjs
python3 -c "
import json
ts=json.load(open('$E/tsconfig.json'))
assert ts['extends']==['@base/x','./tsconfig.quality.json'], ts
" && ok "tsconfig extends chain preserved" || bad "tsconfig extends chain preserved" "assertion failed"
(cd "$E" && git add -A && git -c user.name=test -c user.email=test@test.local commit -q -m stamped)
bash "$S" "$E" --profile nextjs
[ -z "$(cd "$E" && git status --porcelain)" ] && ok "idempotent re-stamp (extends array)" || bad "idempotent re-stamp (extends array)" "$(cd "$E" && git status --porcelain)"

# idempotency: second stamp changes nothing
(cd "$R" && git add -A && git -c user.name=test -c user.email=test@test.local commit -q -m stamped)
bash "$S" "$R" --profile nextjs
[ -z "$(cd "$R" && git status --porcelain)" ] && ok "idempotent re-stamp" || bad "idempotent re-stamp" "$(cd "$R" && git status --porcelain)"

# refuses to clobber a locally-modified stamped file without --force
echo hacked >> "$R/oxlint.config.ts"
rc=0; bash "$S" "$R" --profile nextjs 2>/dev/null || rc=$?
[ "$rc" = 65 ] && ok "refuses modified without --force" || bad "refuses modified without --force" "rc=$rc"
bash "$S" "$R" --profile nextjs --force
grep -q hacked "$R/oxlint.config.ts" && bad "--force restores" "still hacked" || ok "--force restores"

# python profile
P="$(mktemp -d)"; (cd "$P" && git init -q && git config core.hooksPath /dev/null && git -c user.name=test -c user.email=test@test.local commit -q --allow-empty -m init)
bash "$S" "$P" --profile python
[ -f "$P/ruff.toml" ] && [ -f "$P/Makefile.quality" ] && grep -q 'include Makefile.quality' "$P/Makefile" \
  && ok "python profile stamps + Makefile include" || bad "python profile" "files missing"
python3 -c "import json; assert json.load(open('$P/.quality-kit.json'))['runner']=='make'" \
  && ok "python runner=make" || bad "python runner=make" "wrong runner"

rc=0; bash "$S" "$R" --profile bogus 2>/dev/null || rc=$?
[ "$rc" = 64 ] && ok "unknown profile usage error" || bad "unknown profile usage error" "rc=$rc"

# repo-owned override keys survive a re-stamp byte-exact (same contract as
# pendingFlags) — a reset here would wipe the ratchet's memory
O="$(mktemp -d)"
(cd "$O" && git init -q && git config core.hooksPath /dev/null \
  && printf '{"name":"o"}' > package.json && printf '{}' > tsconfig.json \
  && git add -A && git -c user.name=test -c user.email=test@test.local commit -q -m init)
bash "$S" "$O" --profile node >/dev/null
python3 -c "
import json
p='$O/.quality-kit.json'; d=json.load(open(p))
d['ruleOverrides']['burnDown']={'func-style':12}
d['ruleOverrides']['permanent']={'import/no-default-export':{'level':'off','why':'framework requires it'}}
d['ignoreOverrides']=['src/generated/**']
d['customRepoKey']='keep'                # hypothetical future top-level key, unknown to the stamper
d['ruleOverrides']['futureSubkey']={}     # hypothetical future ruleOverrides subkey, unknown to the stamper
json.dump(d,open(p,'w'))"
bash "$S" "$O" --profile node >/dev/null
python3 -c "
import json
d=json.load(open('$O/.quality-kit.json'))
assert d['ruleOverrides']['burnDown']=={'func-style':12}, d
assert d['ruleOverrides']['permanent']['import/no-default-export']['why']=='framework requires it', d
assert d['ignoreOverrides']==['src/generated/**'], d
assert d.get('customRepoKey')=='keep', f'stamper dropped an unknown top-level repo-owned key on re-stamp: {d}'
assert d['ruleOverrides'].get('futureSubkey')=={}, f'stamper dropped an unknown ruleOverrides subkey on re-stamp: {d}'
" && ok "override keys survive re-stamp" || bad "override keys survive re-stamp" "assertion failed"

# engines.node is setdefault, not canonical-wins: a repo that declared a
# STRICTER floor made a real decision, and clobbering it to the kit's ">=22.12.0"
# would silently LOWER a floor while looking like a routine re-stamp.
G="$(mktemp -d)"
(cd "$G" && git init -q && git config core.hooksPath /dev/null \
  && printf '{"name":"g","engines":{"node":">=24.0.0","npm":">=10"}}' > package.json \
  && printf '{}' > tsconfig.json \
  && git add -A && git -c user.name=test -c user.email=test@test.local commit -q -m init)
bash "$S" "$G" --profile node >/dev/null 2>&1
python3 -c "
import json
e=json.load(open('$G/package.json'))['engines']
assert e['node']=='>=24.0.0', f'stamper lowered a stricter engines.node floor: {e}'
assert e['npm']=='>=10', f'stamper dropped a repo-owned engines key: {e}'
" && ok "stamp never lowers a stricter engines.node" || bad "stamp never lowers a stricter engines.node" "assertion failed"

# FIX (codex pre-commit, round 17): npm requires engines to be an OBJECT, and a
# malformed non-object one must not crash the stamper on the very repo it is
# supposed to repair.
B="$(mktemp -d)"
(cd "$B" && git init -q && git config core.hooksPath /dev/null \
  && printf '{"name":"b","engines":"node >=20"}' > package.json \
  && printf '{}' > tsconfig.json \
  && git add -A && git -c user.name=test -c user.email=test@test.local commit -q -m init)
rc=0; bash "$S" "$B" --profile node >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] && ok "stamp survives a non-object engines" || bad "stamp survives a non-object engines" "rc=$rc"
python3 -c "
import json
e=json.load(open('$B/package.json'))['engines']
want=json.load(open('$DIR/../ts/engines.json'))['node']
assert isinstance(e, dict) and e['node']==want, e
" && ok "a non-object engines is replaced with the kit floor" || bad "a non-object engines is replaced with the kit floor" "assertion failed"

# first stamp without a toolchain must still succeed, leaving burnDown empty and
# naming the follow-up command (stamp itself stays offline and deterministic).
# Deterministic regardless of the HOST's own tooling: baseline-rules.sh checks
# THIS repo's own node_modules/.bin/oxlint (never populated here — no npm ci
# ran), not any globally installed linter, so this can't flake on a box that
# happens to have oxlint/ruff/uvx on PATH.
N="$(mktemp -d)"
(cd "$N" && git init -q && git config core.hooksPath /dev/null \
  && printf '{"name":"n"}' > package.json && printf '{}' > tsconfig.json \
  && git add -A && git -c user.name=test -c user.email=test@test.local commit -q -m init)
out="$(bash "$S" "$N" --profile node 2>&1)"
python3 -c "
import json
d=json.load(open('$N/.quality-kit.json'))
assert d['ruleOverrides']['burnDown']=={}, d
" && ok "first stamp without toolchain leaves burnDown empty" || bad "first stamp without toolchain leaves burnDown empty" "assertion failed"
echo "$out" | grep -q "baseline-rules.sh" && ok "stamp names the baseline follow-up" || bad "stamp names the baseline follow-up" "$out"

# a re-stamp must NOT regenerate or reset an existing burn-down
python3 -c "
import json; p='$N/.quality-kit.json'; d=json.load(open(p))
d['ruleOverrides']['burnDown']={'func-style':7}; json.dump(d,open(p,'w'))"
bash "$S" "$N" --profile node >/dev/null 2>&1
python3 -c "
import json
d=json.load(open('$N/.quality-kit.json'))
assert d['ruleOverrides']['burnDown']=={'func-style':7}, d
" && ok "re-stamp does not regenerate the burn-down" || bad "re-stamp does not regenerate the burn-down" "assertion failed"

# Mature repos already have non-empty ledgers, so a plain "seed only when
# empty" policy would turn newly shipped fleet rules into an immediate red
# wall. Seed this cohort once, merge only missing rules, and never reset either
# an existing count or a shape count after the cohort marker lands.
if [ -n "${OXLINT_BIN:-}" ] && [ -x "$OXLINT_BIN" ]; then
  U="$(mk_ts_repo)"
  bash "$S" "$U" --profile node >/dev/null 2>&1
  python3 -c "
import json
p='$U/.quality-kit.json'; d=json.load(open(p))
d['ruleOverrides']['burnDown']={'func-style':7}
json.dump(d,open(p,'w'))"
  printf 'export function shape(value: number) {\n' > "$U/shape.ts"
  for i in $(seq 1 10); do printf '  if (value === %s) return %s;\n' "$i" "$i" >> "$U/shape.ts"; done
  printf '  return 0;\n}\n' >> "$U/shape.ts"
  NM="$(cd "$(dirname "$OXLINT_BIN")/.." && pwd)"
  mkdir -p "$U/node_modules/.bin"
  ln -s "$NM/oxlint" "$U/node_modules/oxlint"
  ln -s "$NM/ultracite" "$U/node_modules/ultracite"
  # The focused CI toolchain intentionally lacks tsgolint. Keep the production
  # script unchanged but strip only --type-aware in this shape-rule fixture;
  # these four rules are AST-only and the real pinned Oxlint still executes.
  printf '#!/usr/bin/env bash\nargs=()\nfor arg in "$@"; do [ "$arg" = --type-aware ] || args+=("$arg"); done\nexec %q "${args[@]}"\n' "$OXLINT_BIN" > "$U/node_modules/.bin/oxlint"
  chmod +x "$U/node_modules/.bin/oxlint"
  bash "$S" "$U" --profile node >/dev/null 2>&1
  python3 -c "
import json
d=json.load(open('$U/.quality-kit.json')); burn=d['ruleOverrides']['burnDown']
assert burn['func-style']==7, ('existing count reset', burn)
assert burn['complexity']==1, ('new shape violation not seeded', burn)
assert d['shapeGateVersion']==1, d
" && ok "TS upgrade seeds missing shape debt without resetting existing counts" || bad "TS upgrade seeds missing shape debt without resetting existing counts" "assertion failed"

  # A later violation must not be silently absorbed by another re-stamp.
  cp "$U/shape.ts" "$U/shape-two.ts"
  bash "$S" "$U" --profile node >/dev/null 2>&1
  python3 -c "
import json
d=json.load(open('$U/.quality-kit.json'))
assert d['ruleOverrides']['burnDown']['complexity']==1, d
" && ok "shape cohort marker prevents later re-baselining" || bad "shape cohort marker prevents later re-baselining" "count changed"
else
  echo "SKIP TS shape upgrade seed (set OXLINT_BIN to the pinned toolchain)"
fi

if command -v ruff >/dev/null 2>&1; then
  V="$(mktemp -d)"
  (cd "$V" && git init -q && git config core.hooksPath /dev/null \
    && printf 'def test_smoke():\n    assert True\n' > test_smoke.py \
    && git add -A && git -c user.name=test -c user.email=test@test.local commit -q -m init)
  bash "$S" "$V" --profile python >/dev/null 2>&1
  python3 -c "
import json
p='$V/.quality-kit.json'; d=json.load(open(p))
d.pop('shapeGateVersion', None)
d['ruleOverrides']['burnDown']={'F401':7}
json.dump(d,open(p,'w'))"
  printf 'def shape(value: int) -> int:\n' > "$V/shape.py"
  for i in $(seq 1 10); do printf '    if value == %s:\n        return %s\n' "$i" "$i" >> "$V/shape.py"; done
  printf '    return 0\n' >> "$V/shape.py"
  bash "$S" "$V" --profile python >/dev/null 2>&1
  python3 -c "
import json
d=json.load(open('$V/.quality-kit.json')); burn=d['ruleOverrides']['burnDown']
assert burn['F401']==7, ('existing count reset', burn)
assert burn['C901']==1, ('new Python shape violation not seeded', burn)
assert d['shapeGateVersion']==1, d
" && ok "Python upgrade seeds C901 without resetting existing counts" || bad "Python upgrade seeds C901 without resetting existing counts" "assertion failed"
else
  echo "SKIP Python shape upgrade seed (ruff unavailable)"
fi

# ORDERING REGRESSION: on a python first stamp the burn-down is seeded and THEN
# ruff.toml is rendered. Reverse the two and the rendered file omits every rule
# just seeded — the repo goes red on day one and can never match a fresh render.
if command -v uvx >/dev/null 2>&1 || command -v ruff >/dev/null 2>&1; then
  Y="$(mktemp -d)"
  (cd "$Y" && git init -q && git config core.hooksPath /dev/null \
    && printf 'import sys\nimport os\n\nx = 1\n' > a.py \
    && printf 'def test_smoke():\n    assert True\n' > test_smoke.py \
    && git add -A && git -c user.name=test -c user.email=test@test.local commit -q -m init)
  bash "$S" "$Y" --profile python >/dev/null 2>&1
  python3 -c "
import json
d=json.load(open('$Y/.quality-kit.json'))
burn=d['ruleOverrides']['burnDown']
assert burn, 'first stamp should have seeded a burn-down from the real violations'
toml=open('$Y/ruff.toml').read()
for rule in burn:
    assert rule in toml, (f'seeded rule {rule} missing from rendered ruff.toml — '
                          'the render ran BEFORE the seed; swap the two blocks in stamp.sh')
" && ok "python first stamp renders ruff.toml AFTER seeding" || bad "python first stamp renders ruff.toml AFTER seeding" "assertion failed"
  # and the freshly stamped python repo must be drift-clean
  KIT_DIR="$(cd "$(dirname "$S")/.." && pwd)" bash "$(dirname "$S")/check-drift.sh" "$Y" >/dev/null 2>&1 \
    && ok "python first stamp is drift-clean" || bad "python first stamp is drift-clean" "drift gate rejected a fresh stamp"
else
  echo "SKIP python first-stamp ordering (no ruff/uvx available)"
fi

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
