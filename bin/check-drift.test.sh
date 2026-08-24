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
          # I2 profile/dependency guard has something real to cross-check, and a
          # package-lock.json because the nextjs floor check reads the version
          # `npm ci` would actually install, not the range package.json declares).
          # $1 overrides the locked next version; the default clears the floor.
  local r nv="${1:-16.3.1}"; r="$(mktemp -d)"
  (cd "$r" && git init -q && git config core.hooksPath /dev/null \
    && printf '{"name":"fix","dependencies":{"next":"^%s"},"scripts":{"build":"true"}}' "$nv" > package.json \
    && printf '{"lockfileVersion":3,"packages":{"node_modules/next":{"version":"%s"}}}' "$nv" > package-lock.json \
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

# I3: the nextjs `next >= 16.3.1` floor (cockpit#87). Below it, `next build`
# segfaults under CI=1 against the kit's pinned typescript@7 while a local build
# passes — so the gate is the only place this is visible before production.
R="$(fresh 16.2.4)"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*next 16.2.4 is below" && ok "next below the floor caught" || bad "next below the floor caught" "$out"

R="$(fresh 17.0.0)"   # a future major is above the floor, not below it
run "$R" >/dev/null && ok "next above the floor stays clean" || bad "next above the floor stays clean" "$(run "$R" || true)"

# a prerelease of the floor sorts BELOW the floor — 16.3.1-canary.0 is not 16.3.1
R="$(fresh 16.3.1-canary.0)"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*is below" && ok "prerelease of the floor caught" || bad "prerelease of the floor caught" "$out"

# the RANGE in package.json must not be what's trusted: ^16.3.1 declared while
# the lockfile — the thing npm ci installs — still pins a segfaulting 16.2.4.
R="$(fresh 16.2.4)"
python3 -c "
import json; p='$R/package.json'; d=json.load(open(p)); d['dependencies']['next']='^16.3.1'; json.dump(d,open(p,'w'))"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*is below" && ok "conforming range cannot mask a stale lockfile" || bad "conforming range cannot mask a stale lockfile" "$out"

# fail-closed: no lockfile means the floor is unverifiable, which must not read as a pass
R="$(fresh)"; rm -f "$R/package-lock.json"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*without package-lock.json" && ok "missing lockfile fails closed" || bad "missing lockfile fails closed" "$out"

# fail-closed: a lockfile present but pinning no next at all
R="$(fresh)"; printf '{"lockfileVersion":3,"packages":{}}' > "$R/package-lock.json"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*pins no next version" && ok "lockfile without next fails closed" || bad "lockfile without next fails closed" "$out"

# lockfileVersion 1 keyed its deps flat rather than by install path
R="$(fresh)"; printf '{"lockfileVersion":1,"dependencies":{"next":{"version":"16.2.4"}}}' > "$R/package-lock.json"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*is below" && ok "v1 lockfile shape still checked" || bad "v1 lockfile shape still checked" "$out"

# the floor is a nextjs-profile rule — a vite repo carrying an old next-like pin is not its business
R="$(fresh 16.2.4)"
python3 -c "
import json; p='$R/package.json'; d=json.load(open(p)); del d['dependencies']['next']; d['dependencies']['react']='^18'; json.dump(d,open(p,'w'))
q='$R/.quality-kit.json'; d=json.load(open(q)); d['profile']='vite'; json.dump(d,open(q,'w'))"
cp "$KITROOT/ts/oxlint.config.vite.ts" "$R/oxlint.config.ts"
python3 -c "
import json; p='$R/package.json'; d=json.load(open(p)); d['scripts']=json.load(open('$KITROOT/ts/package-scripts.vite.json')); json.dump(d,open(p,'w'))"
out="$(run "$R" || true)"
echo "$out" | grep -q "is below" && bad "the floor does not apply off the nextjs profile" "$out" || ok "the floor does not apply off the nextjs profile"

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

# bool is an int subclass in python — {"rule": true} must not sail through as count 1
R="$(fresh)"; qk_mut "$R" "d['ruleOverrides']['burnDown']={'x/y':True}"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*positive" && ok "bool burnDown count rejected" || bad "bool burnDown count rejected (bool must not pass as count 1)" "$out"

R="$(fresh)"; qk_mut "$R" "d['ignoreOverrides']=[{'glob':'x'}]"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*ignoreOverrides" && ok "non-string ignoreOverrides rejected" || bad "non-string ignoreOverrides rejected" "$out"

R="$(fresh)"; qk_mut "$R" "d['ruleOverrides']='nope'"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*ruleOverrides" && ok "malformed ruleOverrides rejected" || bad "malformed ruleOverrides rejected" "$out"

# burnDown/permanent must each be an object, or the per-rule loops below would
# AttributeError on .items() instead of naming a remedy
R="$(fresh)"; qk_mut "$R" "d['ruleOverrides']={'burnDown':'oops','permanent':{}}"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*must both be objects" && ok "non-object burnDown container rejected" || bad "non-object burnDown container rejected (would crash instead of naming a remedy)" "$out"

# a permanent[rule] entry that isn't an object would crash spec.get(...) below
R="$(fresh)"; qk_mut "$R" "d['ruleOverrides']['permanent']={'x/y':'off'}"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*must be an object with level and why" && ok "non-object permanent entry rejected" || bad "non-object permanent entry rejected (would crash instead of naming a remedy)" "$out"

# a well-formed override set is clean
R="$(fresh)"; qk_mut "$R" "d['ruleOverrides']['permanent']={'import/no-default-export':{'level':'off','why':'Next.js pages require default exports'}}; d['ignoreOverrides']=['src/generated/**']"
run "$R" >/dev/null && ok "valid overrides stay clean" || bad "valid overrides stay clean" "$(run "$R" || true)"

# warn IS renderable on a ts profile (oxlint has a warn severity) — only the
# python profile (ruff, no warn severity) must reject it; prove the positive
# direction, not just the python-side rejection below
R="$(fresh)"; qk_mut "$R" "d['ruleOverrides']['permanent']={'some/rule':{'level':'warn','why':'staged rollout'}}"
run "$R" >/dev/null && ok "warn level stays clean on ts profile" || bad "warn level stays clean on ts profile" "$(run "$R" || true)"

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

# a hand-edited rendered ruff.toml must be caught (the rendered file is as
# byte-owned as a copied one — the declaration site is .quality-kit.json)
printf '\nextend-ignore = ["F401"]\n' >> "$PYR/ruff.toml"
out="$(run "$PYR" || true)"
echo "$out" | grep -q "DRIFT.*ruff.toml" && ok "hand-edited ruff.toml caught" || bad "hand-edited ruff.toml caught" "$out"
bash "$DIR/render-ruff.sh" "$PYR" > "$PYR/ruff.toml"

# --- ratchet mode ---
ratchet() { KIT_DIR="$KITROOT" bash "$CD" "$1" --ratchet 2>&1; }

# default mode must stay toolchain-free and ignore burn-down counts entirely
R="$(fresh)"; qk_mut "$R" "d['ruleOverrides']['burnDown']={'func-style':999}"
run "$R" >/dev/null && ok "default mode ignores burn-down counts" || bad "default mode ignores burn-down counts" "$(run "$R" || true)"

# unknown flag is a usage error, not a silent pass
rc=0; KIT_DIR="$KITROOT" bash "$CD" "$R" --bogus >/dev/null 2>&1 || rc=$?
[ "$rc" = 64 ] && ok "unknown flag is a usage error" || bad "unknown flag is a usage error" "rc=$rc"

# python ratchet against real ruff: 3 unused imports recorded as 2 must fail
if command -v uvx >/dev/null 2>&1; then
  Q="$(mktemp -d)"; (cd "$Q" && git init -q && git config core.hooksPath /dev/null \
    && git -c user.name=ci -c user.email=ci@example.com commit -q --allow-empty -m init)
  bash "$DIR/stamp.sh" "$Q" --profile python >/dev/null 2>&1
  printf 'import sys\nimport os\n\nx = 1\n' > "$Q/a.py"
  printf 'import json\n\ny = 2\n' > "$Q/b.py"

  qk_mut "$Q" "d['ruleOverrides']['burnDown']={'F401':2}"
  bash "$DIR/render-ruff.sh" "$Q" > "$Q/ruff.toml"
  out="$(ratchet "$Q" || true)"
  echo "$out" | grep -q "DRIFT.*F401" && ok "grown count caught (python)" || bad "grown count caught (python)" "$out"

  qk_mut "$Q" "d['ruleOverrides']['burnDown']={'F401':3}"
  bash "$DIR/render-ruff.sh" "$Q" > "$Q/ruff.toml"
  ratchet "$Q" >/dev/null && ok "exact count passes (python)" || bad "exact count passes (python)" "$(ratchet "$Q" || true)"

  qk_mut "$Q" "d['ruleOverrides']['burnDown']={'F401':5}"
  bash "$DIR/render-ruff.sh" "$Q" > "$Q/ruff.toml"
  ratchet "$Q" >/dev/null && ok "count as ceiling passes (python)" || bad "count as ceiling passes (python)" "$(ratchet "$Q" || true)"

  # burn-down complete → the entry must be removed, not left at a stale count
  qk_mut "$Q" "d['ruleOverrides']['burnDown']={'B008':4}"
  bash "$DIR/render-ruff.sh" "$Q" > "$Q/ruff.toml"
  out="$(ratchet "$Q" || true)"
  echo "$out" | grep -q "DRIFT.*B008.*remove" && ok "completed burn-down demands removal (python)" || bad "completed burn-down demands removal (python)" "$out"

  # A1 (the merge blocker): a linter CRASH mid-run (malformed ruff.toml, same
  # config-parse failure baseline-rules.test.sh already proves exits 4) must
  # NOT be read as "{} == all burn-down complete" — that reading would tell an
  # automated repair-loop to delete the whole ledger over a transient crash.
  qk_mut "$Q" "d['ruleOverrides']['burnDown']={'F401':3}"
  printf 'this is not valid toml [[[\n' > "$Q/ruff.toml"
  out="$(ratchet "$Q" || true)"
  echo "$out" | grep -q "DRIFT.*linter failed to run" && ok "linter crash reported, not silently absorbed (python)" || bad "linter crash reported, not silently absorbed (python)" "$out"
  # the erroneous per-rule "complete, remove it" remedy (what a crash
  # misread as zero violations would have produced for every burn-down rule)
  # must not appear — note the fix's OWN message legitimately contains the
  # bare word "complete" ("must not be read as 'all burn-down complete'"), so
  # this checks the specific broken phrasing, not a bare substring.
  echo "$out" | grep -q "burn-down complete for" && bad "crash must not read as burn-down complete" "$out" || ok "crash not read as burn-down complete"
  echo "$out" | grep -q "remove the entry" && bad "crash must not demand removing the ledger entry" "$out" || ok "crash does not demand removing the entry"

  # FIX (CodeRabbit): malformed ruleOverrides (a string, not a dict) must not
  # traceback under --ratchet either — the ratchet's own BURN extraction now
  # coerces a non-dict ruleOverrides to {}, same as render-ruff.sh already
  # does; check_overrides() in the static pass is still what names the DRIFT
  # remedy. This locks the fix for the ratchet's own read of ruleOverrides.
  bash "$DIR/render-ruff.sh" "$Q" > "$Q/ruff.toml"
  qk_mut "$Q" "d['ruleOverrides']='nope'"
  out="$(ratchet "$Q" || true)"
  echo "$out" | grep -q "DRIFT.*ruleOverrides" && ok "malformed ruleOverrides caught under --ratchet" || bad "malformed ruleOverrides caught under --ratchet" "$out"
  echo "$out" | grep -q "Traceback" && bad "malformed ruleOverrides under --ratchet must not traceback" "$out" || ok "malformed ruleOverrides under --ratchet does not traceback"

  # FIX (CodeRabbit follow-up): a malformed NESTED burnDown (non-dict) must also
  # be coerced — otherwise it builds a garbage --select and surfaces a
  # misleading 'linter failed' DRIFT on top of the correct schema DRIFT. The
  # ratchet coerces a non-dict burnDown to {} so it's a clean no-op; the static
  # check_overrides names the real remedy.
  qk_mut "$Q" "d['ruleOverrides']={'burnDown':'nope','permanent':{}}"
  bash "$DIR/render-ruff.sh" "$Q" > "$Q/ruff.toml"
  out="$(ratchet "$Q" || true)"
  echo "$out" | grep -q "DRIFT.*burnDown.*both be objects" && ok "malformed nested burnDown caught under --ratchet" || bad "malformed nested burnDown caught under --ratchet" "$out"
  echo "$out" | grep -q "Traceback" && bad "malformed nested burnDown under --ratchet must not traceback" "$out" || ok "malformed nested burnDown under --ratchet does not traceback"
  echo "$out" | grep -q "linter failed to run" && bad "malformed nested burnDown must not surface a misleading linter-failed DRIFT" "$out" || ok "malformed nested burnDown gives no misleading linter-failed message"
else
  echo "SKIP python ratchet (no uvx available)"
fi

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
