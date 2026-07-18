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
bash "$S" "$R" --profile nextjs

for f in .quality/format-changed.sh .quality/stop-validate.sh .quality/suppression-baseline.json \
         .quality/manifest.sha256 .quality-kit.json oxlint.config.ts oxfmt.config.ts \
         tsconfig.quality.json .github/workflows/quality.yml .codex/hooks.json .claude/settings.json; do
  [ -f "$R/$f" ] && ok "stamped $f" || bad "stamped $f" "missing"
done

python3 -c "
import json
qk=json.load(open('$R/.quality-kit.json'))
assert qk=={'version':'0.1.3','profile':'nextjs','runner':'npm','pendingFlags':[]}, qk
p=json.load(open('$R/package.json'))
assert p['scripts']['dev']=='next dev', 'existing scripts preserved'
assert 'validate' in p['scripts'] and 'validate:fast' in p['scripts']
assert p['devDependencies']['oxlint']=='1.74.0' and p['devDependencies']['typescript']=='7.0.2'
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

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
