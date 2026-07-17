#!/usr/bin/env bash
# What: tamper-case tests for check-drift.sh. Where: quality-kit/bin.
# Why:  this is the unforgeable gate — every bypass an agent could attempt
#       must be a covered case here.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
KITROOT="$(cd "$DIR/.." && pwd)"
CD="$DIR/check-drift.sh"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }

fresh() { # stamped nextjs fixture repo
  local r; r="$(mktemp -d)"
  (cd "$r" && git init -q && git config core.hooksPath /dev/null && printf '{"name":"fix","scripts":{"build":"true"}}' > package.json \
    && printf '{}' > tsconfig.json && git add -A && git -c user.name=ci -c user.email=ci@example.com commit -q -m init)
  bash "$DIR/stamp.sh" "$r" --profile nextjs >/dev/null
  echo "$r"
}
run() { KIT_DIR="$KITROOT" bash "$CD" "$1" 2>&1; }

R="$(fresh)"
run "$R" >/dev/null && ok "freshly stamped repo is clean" || bad "freshly stamped repo is clean" "$(run "$R")"

R="$(fresh)"; echo "// weakened" >> "$R/oxlint.config.ts"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*oxlint.config.ts" && ok "edited stamped file caught" || bad "edited stamped file caught" "$out"

R="$(fresh)"
python3 -c "
import json; p='$R/tsconfig.json'; d=json.load(open(p))
d.setdefault('compilerOptions',{})['noUncheckedIndexedAccess']=False
json.dump(d,open(p,'w'))"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*noUncheckedIndexedAccess" && ok "protected flag override caught" || bad "protected flag override caught" "$out"

R="$(fresh)"   # same override but sanctioned via pendingFlags → allowed
python3 -c "
import json
p='$R/tsconfig.json'; d=json.load(open(p)); d.setdefault('compilerOptions',{})['noUncheckedIndexedAccess']=False; json.dump(d,open(p,'w'))
q='$R/.quality-kit.json'; d=json.load(open(q)); d['pendingFlags']=['noUncheckedIndexedAccess']; json.dump(d,open(q,'w'))"
run "$R" >/dev/null && ok "pendingFlags sanctions staging" || bad "pendingFlags sanctions staging" "$(run "$R" || true)"

R="$(fresh)"
python3 -c "
import json; p='$R/package.json'; d=json.load(open(p)); d['scripts']['validate']='true'; json.dump(d,open(p,'w'))"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*validate" && ok "rewired validate script caught" || bad "rewired validate script caught" "$out"

R="$(fresh)"; printf '// @ts-ignore\nconst q=1;\n' > "$R/new.ts"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*suppression" && ok "new suppression over budget caught" || bad "new suppression over budget caught" "$out"

R="$(fresh)"   # merged .claude/settings.json must keep the kit hooks
python3 -c "
import json; p='$R/.claude/settings.json'; d=json.load(open(p)); d['hooks'].pop('Stop'); json.dump(d,open(p,'w'))"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*Stop hook" && ok "removed claude Stop hook caught" || bad "removed claude Stop hook caught" "$out"

R="$(fresh)"   # matcher tampering must also fail (full-entry equality)
python3 -c "
import json; p='$R/.claude/settings.json'; d=json.load(open(p)); d['hooks']['PostToolUse'][0]['matcher']='NeverMatches'; json.dump(d,open(p,'w'))"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*PostToolUse" && ok "tampered matcher caught" || bad "tampered matcher caught" "$out"

PYR="$(mktemp -d)"; (cd "$PYR" && git init -q && git config core.hooksPath /dev/null && git -c user.name=ci -c user.email=ci@example.com commit -q --allow-empty -m init)
bash "$DIR/stamp.sh" "$PYR" --profile python >/dev/null
run "$PYR" >/dev/null && ok "stamped python repo clean" || bad "stamped python repo clean" "$(run "$PYR" || true)"
sed -i '/include Makefile.quality/d' "$PYR/Makefile"
out="$(run "$PYR" || true)"
echo "$out" | grep -q "DRIFT.*Makefile" && ok "dropped Makefile include caught" || bad "dropped Makefile include caught" "$out"

R="$(fresh)"
python3 -c "
import json; p='$R/.quality-kit.json'; d=json.load(open(p)); d['version']='0.0.9'; json.dump(d,open(p,'w'))"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*0.0.9" && ok "pin/kit mismatch caught" || bad "pin/kit mismatch caught" "$out"

# sanctioned adjustment 2: brief-verbatim `cmd; rc=$?` would abort here under
# set -e on the expected nonzero (66) exit — bracket with `rc=0; cmd || rc=$?`
rc=0; KIT_DIR="$KITROOT" bash "$CD" "$(mktemp -d)" 2>/dev/null || rc=$?
[ "$rc" = 66 ] && ok "unstamped repo exit 66" || bad "unstamped repo exit 66" "rc=$rc"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
