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

fresh() { # stamped nextjs fixture repo (carries a "next" dependency so the
          # I2 profile/dependency guard has something real to cross-check)
  local r; r="$(mktemp -d)"
  (cd "$r" && git init -q && git config core.hooksPath /dev/null && printf '{"name":"fix","dependencies":{"next":"^14.2.0"},"scripts":{"build":"true"}}' > package.json \
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

# C1: a "/*"..."*/" pair split across two separate string VALUES must not be
# misread as an actual comment span — that would blank the real override
# from the gate's view while tsc's own string-aware parser still honors it.
R="$(fresh)"
printf '{"extends":"./tsconfig.quality.json","_a":"/*","compilerOptions":{"strict":true,"noUncheckedIndexedAccess":false},"_b":"*/"}' > "$R/tsconfig.json"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*noUncheckedIndexedAccess" && ok "comment-in-string decoy does not hide flag override" || bad "comment-in-string decoy does not hide flag override" "$out"

# M1 regression: a legit string value containing comment-like characters
# (e.g. a glob) must parse cleanly, not crash the comment stripper.
R="$(fresh)"
printf '{"extends":"./tsconfig.quality.json","compilerOptions":{"tsBuildInfoFile":"./x/*/y"}}' > "$R/tsconfig.json"
run "$R" >/dev/null && ok "comment-like string value does not crash the parser" || bad "comment-like string value does not crash the parser" "$(run "$R" || true)"

# I1(a): extends reordered so the quality fragment isn't last — later entries
# win in TS, so a trailing ./evil.json would actually govern.
R="$(fresh)"
python3 -c "
import json; p='$R/tsconfig.json'; d=json.load(open(p)); d['extends']=['./tsconfig.quality.json','./evil.json']; json.dump(d,open(p,'w'))"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*extends" && ok "extends reordered (quality not last) caught" || bad "extends reordered (quality not last) caught" "$out"

# I1(b): a decoy path that merely contains the real filename as a substring.
R="$(fresh)"
python3 -c "
import json; p='$R/tsconfig.json'; d=json.load(open(p)); d['extends']='./sub/tsconfig.quality.json'; json.dump(d,open(p,'w'))"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*extends" && ok "extends path decoy caught" || bad "extends path decoy caught" "$out"

# I1(c): legit pre-existing extends chain, quality fragment last — clean.
R="$(fresh)"
python3 -c "
import json; p='$R/tsconfig.json'; d=json.load(open(p)); d['extends']=['@base/x','./tsconfig.quality.json']; json.dump(d,open(p,'w'))"
run "$R" >/dev/null && ok "extends array with quality last stays clean" || bad "extends array with quality last stays clean" "$(run "$R" || true)"

# I2: relabeling within the ts profile family (nextjs -> node) isn't caught
# by the byte-owned same() checks since they just compare against the new
# profile's own files — the repo's actual dependencies (next present) must
# still catch the mismatch.
R="$(fresh)"
python3 -c "
import json; p='$R/.quality-kit.json'; d=json.load(open(p)); d['profile']='node'; json.dump(d,open(p,'w'))"
cp "$KITROOT/ts/oxlint.config.node.ts" "$R/oxlint.config.ts"
python3 -c "
import json
p='$R/package.json'; d=json.load(open(p))
d['scripts']=json.load(open('$KITROOT/ts/package-scripts.node.json'))
json.dump(d,open(p,'w'))"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*inconsistent with dependencies" && ok "profile relabeled within ts family (next dependency) caught" || bad "profile relabeled within ts family (next dependency) caught" "$out"

# --- overrides schema (static, no toolchain needed) ---
# helper: mutate a fresh fixture's .quality-kit.json, then run drift
qk_mut() { python3 -c "
import json,sys; p=sys.argv[1]; d=json.load(open(p)); exec(sys.argv[2]); json.dump(d,open(p,'w'))" "$1/.quality-kit.json" "$2"; }

R="$(fresh)"; qk_mut "$R" "d['ruleOverrides']['permanent']={'x/y':{'level':'off','why':''}}"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*why" && ok "empty why rejected" || bad "empty why rejected" "$out"

R="$(fresh)"; qk_mut "$R" "d['ruleOverrides']['permanent']={'x/y':{'level':'off','why':'ok'}}; d['ruleOverrides']['burnDown']={'x/y':3}"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*both" && ok "rule in both sections rejected" || bad "rule in both sections rejected" "$out"

R="$(fresh)"; qk_mut "$R" "d['ruleOverrides']['permanent']={'x/y':{'level':'error','why':'ok'}}"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*level" && ok "bad permanent level rejected" || bad "bad permanent level rejected" "$out"

R="$(fresh)"; qk_mut "$R" "d['ruleOverrides']['burnDown']={'x/y':0}"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*positive" && ok "zero burnDown count rejected" || bad "zero burnDown count rejected" "$out"

R="$(fresh)"; qk_mut "$R" "d['ruleOverrides']['burnDown']={'x/y':'many'}"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*positive" && ok "non-int burnDown count rejected" || bad "non-int burnDown count rejected" "$out"

R="$(fresh)"; qk_mut "$R" "d['ignoreOverrides']=[{'glob':'x'}]"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*ignoreOverrides" && ok "non-string ignoreOverrides rejected" || bad "non-string ignoreOverrides rejected" "$out"

R="$(fresh)"; qk_mut "$R" "d['ruleOverrides']='nope'"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*ruleOverrides" && ok "malformed ruleOverrides rejected" || bad "malformed ruleOverrides rejected" "$out"

# a well-formed override set is clean
R="$(fresh)"; qk_mut "$R" "d['ruleOverrides']['permanent']={'import/no-default-export':{'level':'off','why':'Next.js pages require default exports'}}; d['ignoreOverrides']=['src/generated/**']"
run "$R" >/dev/null && ok "valid overrides stay clean" || bad "valid overrides stay clean" "$(run "$R" || true)"

# python profile: warn is unrenderable in ruff, so it must be rejected there
python3 -c "
import json; p='$PYR/.quality-kit.json'; d=json.load(open(p))
d['ruleOverrides']={'burnDown':{},'permanent':{'F401':{'level':'warn','why':'staged'}}}
json.dump(d,open(p,'w'))"
out="$(run "$PYR" || true)"
echo "$out" | grep -q "DRIFT.*warn" && ok "python profile rejects warn level" || bad "python profile rejects warn level" "$out"
python3 -c "
import json; p='$PYR/.quality-kit.json'; d=json.load(open(p))
d['ruleOverrides']={'burnDown':{},'permanent':{}}; json.dump(d,open(p,'w'))"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
