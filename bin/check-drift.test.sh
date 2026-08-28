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
          # smoke.test.ts satisfies the "a stamped repo has tests" gate — vitest
          # exits 1 on an empty collection, so without it every case below would
          # carry a second, unrelated DRIFT. Negative cases delete it explicitly.
  local r nv="${1:-16.3.1}"; r="$(mktemp -d)"
  (cd "$r" && git init -q && git config core.hooksPath /dev/null \
    && printf '{"name":"fix","dependencies":{"next":"^%s"},"scripts":{"build":"true"}}' "$nv" > package.json \
    && printf '{"lockfileVersion":3,"packages":{"node_modules/next":{"version":"%s"}}}' "$nv" > package-lock.json \
    && printf 'import { it } from "vitest";\nit("smoke", () => {});\n' > smoke.test.ts \
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

PYR="$(mktemp -d)"; (cd "$PYR" && git init -q && git config core.hooksPath /dev/null \
  && printf 'def test_smoke():\n    assert True\n' > test_smoke.py \
  && git add -A && git -c user.name=ci -c user.email=ci@example.com commit -q -m init)
bash "$DIR/stamp.sh" "$PYR" --profile python >/dev/null
run "$PYR" >/dev/null && ok "stamped python repo clean" || bad "stamped python repo clean" "$(run "$PYR" || true)"
printf '#!/usr/bin/env bash\nexit 0\n' > "$PYR/.quality/loc-budget.sh"
out="$(run "$PYR" || true)"
echo "$out" | grep -q "DRIFT.*loc-budget" && ok "tampered source-budget gate caught" || bad "tampered source-budget gate caught" "$out"
cp "$KITROOT/bin/loc-budget.sh" "$PYR/.quality/loc-budget.sh"
sed -i '/include Makefile.quality/d' "$PYR/Makefile"
out="$(run "$PYR" || true)"
echo "$out" | grep -q "DRIFT.*Makefile" && ok "dropped Makefile include caught" || bad "dropped Makefile include caught" "$out"
# restore it: $PYR is reused by every python case below, and an unrestored
# mutation here would leak a second, unrelated DRIFT into all of them
printf 'include Makefile.quality\n' >> "$PYR/Makefile"

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

# --- I4: the Node floor (cockpit#87) ---
# The kit's pinned toolchain floors Node at 22.12.0 (ultracite pulls
# commander@15 at a flat >=22.12.0, with no Node 20 branch). Nothing stated it
# until v0.4.3, and the failure never names Node: the stamped quality.yml runs
# Node 24, so only a developer or a delegate on an older Node ever sees it.
set_engines() { python3 -c "
import json,sys; p=sys.argv[1]; d=json.load(open(p)); d['engines']={'node':sys.argv[2]}; json.dump(d,open(p,'w'))" "$1/package.json" "$2"; }

R="$(fresh)"
python3 -c "
import json
d=json.load(open('$R/package.json'))
want=json.load(open('$KITROOT/ts/engines.json'))['node']
assert d.get('engines',{}).get('node')==want, d.get('engines')" \
  && ok "stamp writes engines.node, so a fresh stamp passes this gate" \
  || bad "stamp writes engines.node, so a fresh stamp passes this gate" "stamp.sh did not write the floor"

# Range classification table — the parser is deliberately narrow, so which forms
# it ACCEPTS and which it REFUSES TO GUESS AT are both part of the contract.
# `clean` = the declared floor is provably >= 22.12.0; `below` = the range
# admits an older Node; `unparseable` = fail closed rather than guess.
# The delimiter is ';' and NOT '|' — a '|' delimiter silently swallows the
# "^20.19.0 || >=22.12.0" row (its own '||' becomes two extra fields), leaving
# that row asserting nothing at all. Found by break-probe: inverting the OR rule
# in _range_floor left the suite green. Hence the catch-all case below.
while IFS=';' read -r rng want; do
  [ -n "$rng" ] || continue
  R="$(fresh)"; set_engines "$R" "$rng"
  out="$(run "$R" || true)"
  case "$want" in
    clean)
      echo "$out" | grep -q "engines.node" \
        && bad "engines.node '$rng' accepted" "$out" || ok "engines.node '$rng' accepted" ;;
    below)
      echo "$out" | grep -q "DRIFT.*engines.node.*below the 22.12.0" \
        && ok "engines.node '$rng' rejected as below the floor" || bad "engines.node '$rng' rejected as below the floor" "$out" ;;
    unparseable)
      echo "$out" | grep -q "DRIFT.*cannot parse engines.node" \
        && ok "engines.node '$rng' fails closed as unparseable" || bad "engines.node '$rng' fails closed as unparseable" "$out" ;;
    *)
      bad "engines.node row '$rng' asserts something" "unknown expectation '$want' — a row that matches no case tests nothing" ;;
  esac
done <<'ROWS'
>=22.12.0;clean
^22.12.0;clean
~22.12.0;clean
>=22.12.0 <23;clean
22.12.x;clean
>=24;clean
23;clean
22.x;below
22;below
>=20;below
>=22.11.0;below
*;below
<23;below
>=20 <23;below
>=20 < 23;below
>= 20;below
>= 22.12.0;clean
>=22.12.0 < 23;clean
^20.19.0 || >=22.12.0;below
>=22.12.0 || ^20.19.0;below
>=22.12.0 <;unparseable
<;unparseable
>=22.12.0 <=22.12.0;clean
>=22.12.0 <=22;clean
>=22.12.0 <=22.12;clean
>=22.12.0 <=22.x;clean
>=22.12.0 <=x;clean
>=22.12.0 <*;clean
20 - 22;unparseable
22.12.0 23;unparseable
^22.12.0 ^23;unparseable
>=22.12.0 >=23;unparseable
>=22.12.0-rc.1;unparseable
>=v22.12.0;unparseable
>=22.12.0+build.1;unparseable
>=twenty;unparseable
>=22.12.0 || 20 - 22;unparseable
>22.12.0;unparseable
>22.11.999;unparseable
> 22.12.0;unparseable
ROWS

# FIX (codex pre-commit, round 14): a contradictory range clears the floor
# arithmetically while matching no Node at all — npm can satisfy it with
# nothing, and an engine-strict install fails everywhere.
for rng in '>=22.12.0 <22.12.0' '>=23 <22' '>=22.12.0 <22.12.0 || >=24 <23' '>=23 <=22' '>=22.12.0 <22'; do
  R="$(fresh)"; set_engines "$R" "$rng"
  out="$(run "$R" || true)"
  echo "$out" | grep -q "DRIFT.*engines.node.*unsatisfiable" && ok "engines.node '$rng' rejected as unsatisfiable" || bad "engines.node '$rng' rejected as unsatisfiable" "$out"
done
# ...but one satisfiable branch is enough, and it is the one that must be judged
R="$(fresh)"; set_engines "$R" '>=22.12.0 <22.12.0 || >=24'
run "$R" >/dev/null && ok "engines.node: an empty branch does not condemn a satisfiable one" || bad "engines.node: an empty branch does not condemn a satisfiable one" "$(run "$R" || true)"
R="$(fresh)"; set_engines "$R" '>=22.12.0 <22.12.0 || >=20'
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*engines.node.*below the 22.12.0" && ok "engines.node: the surviving branch is still floor-checked" || bad "engines.node: the surviving branch is still floor-checked" "$out"

# fail closed: no engines block at all is unverifiable, not a pass
R="$(fresh)"
python3 -c "
import json; p='$R/package.json'; d=json.load(open(p)); d.pop('engines',None); json.dump(d,open(p,'w'))"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*declares no engines.node" && ok "missing engines.node fails closed" || bad "missing engines.node fails closed" "$out"

# a non-object engines (or a non-string node) must fail closed with a remedy,
# not crash the gate into its generic internal-error path
R="$(fresh)"
python3 -c "
import json; p='$R/package.json'; d=json.load(open(p)); d['engines']='node >=22.12.0'; json.dump(d,open(p,'w'))"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*declares no engines.node" && ok "non-object engines fails closed" || bad "non-object engines fails closed" "$out"
echo "$out" | grep -q "internal gate error" && bad "non-object engines must not crash the gate" "$out" || ok "non-object engines does not crash the gate"

# the floor is a TS-toolchain rule, not a nextjs one: every ts profile installs
# ts/pins.json, so the node profile inherits it too
NODEREPO="$(mktemp -d)"
(cd "$NODEREPO" && git init -q && git config core.hooksPath /dev/null \
  && printf '{"name":"n"}' > package.json && printf '{}' > tsconfig.json \
  && printf 'import { it } from "vitest";\nit("smoke", () => {});\n' > smoke.test.ts \
  && git add -A && git -c user.name=ci -c user.email=ci@example.com commit -q -m init)
bash "$DIR/stamp.sh" "$NODEREPO" --profile node >/dev/null
run "$NODEREPO" >/dev/null && ok "stamped node-profile repo clean" || bad "stamped node-profile repo clean" "$(run "$NODEREPO" || true)"
set_engines "$NODEREPO" ">=20"
out="$(run "$NODEREPO" || true)"
echo "$out" | grep -q "DRIFT.*engines.node.*below" && ok "the Node floor applies on the node profile too" || bad "the Node floor applies on the node profile too" "$out"

# ...but NOT on python: that profile has no npm toolchain at all (runner=make),
# so a Node floor there would be meaningless noise.
printf '{"name":"p","engines":{"node":">=20"}}' > "$PYR/package.json"
out="$(run "$PYR" || true)"
echo "$out" | grep -q "engines.node" && bad "the Node floor does not apply on the python profile" "$out" || ok "the Node floor does not apply on the python profile"
rm -f "$PYR/package.json"

# --- I5: a stamped repo must have a test file (cockpit#87) ---
# `test:unit` is in the canonical validate chain and `vitest run` exits 1 on an
# empty collection, so a repo stamped with no tests is red on day one.
R="$(fresh)"; rm "$R/smoke.test.ts"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "ts repo with no test file caught" || bad "ts repo with no test file caught" "$out"

# every filename vitest's default include collects must count, including the
# .cjs/.mjs and .tsx/.jsx arms and files nested arbitrarily deep
for f in a.test.ts a.spec.ts a.test.tsx a.spec.jsx a.test.mts a.spec.cjs src/deep/nested/a.test.js; do
  R="$(fresh)"; rm "$R/smoke.test.ts"
  mkdir -p "$(dirname "$R/$f")"; printf 'import { it } from "vitest";\nit("smoke", () => {});\n' > "$R/$f"
  run "$R" >/dev/null && ok "vitest collects $f — counts as a test file" || bad "vitest collects $f — counts as a test file" "$(run "$R" || true)"
done

# ...and a filename it does NOT collect must not satisfy the gate — matching the
# runner's real rules is the point; a looser "does the word test appear" check
# would pass a repo whose CI still collects nothing
for f in tests/helper.ts testing.ts a.test.txt a.tests.ts test.ts; do
  R="$(fresh)"; rm "$R/smoke.test.ts"
  mkdir -p "$(dirname "$R/$f")"; printf 'import { it } from "vitest";\nit("smoke", () => {});\n' > "$R/$f"
  out="$(run "$R" || true)"
  echo "$out" | grep -q "DRIFT.*no test file found" && ok "vitest does not collect $f — not a test file" || bad "vitest does not collect $f — not a test file" "$out"
done

# FIX (codex pre-commit, round 6): a matching FILENAME that declares no suite is
# collected by vitest and then fails — "No test suite found in file" — which is
# the same red validate on day one. So the ts arm checks content too, and every
# ts fixture above carries a real `it(...)` rather than a bare export.
R="$(fresh)"; rm "$R/smoke.test.ts"; printf 'export const a = 1;\n' > "$R/a.test.ts"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "vitest: a matching file declaring no suite does not satisfy the gate" || bad "vitest: a matching file declaring no suite does not satisfy the gate" "$out"

for decl in 'describe("s", () => {});' 'test("s", () => {});' 'it.each([1])("s", () => {});' 'test.skip("s", () => {});' 'bench("s", () => {});'; do
  R="$(fresh)"; rm "$R/smoke.test.ts"
  printf 'import { describe, it, test, suite, bench } from "vitest";\n%s\n' "$decl" > "$R/a.test.ts"
  run "$R" >/dev/null && ok "vitest declaration form: $decl" || bad "vitest declaration form: $decl" "$(run "$R" || true)"
done

# FIX (codex pre-commit, round 7): a wholly commented-out test file registers no
# suite either — a real and ordinary way to end up red on day one.
R="$(fresh)"; rm "$R/smoke.test.ts"; printf 'import { it } from "vitest";\n// it("smoke", () => {});\nexport const a = 1;\n' > "$R/a.test.ts"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "vitest: a line-commented declaration is not a suite" || bad "vitest: a line-commented declaration is not a suite" "$out"
R="$(fresh)"; rm "$R/smoke.test.ts"; printf 'import { it } from "vitest";\n/*\nit("smoke", () => {});\n*/\nexport const a = 1;\n' > "$R/a.test.ts"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "vitest: a block-commented declaration is not a suite" || bad "vitest: a block-commented declaration is not a suite" "$out"
# ...and a real declaration below a comment is still found
R="$(fresh)"; rm "$R/smoke.test.ts"; printf 'import { it } from "vitest";\n// it("old", () => {});\nit("smoke", () => {});\n' > "$R/a.test.ts"
run "$R" >/dev/null && ok "vitest: a live declaration below a commented one still counts" || bad "vitest: a live declaration below a commented one still counts" "$(run "$R" || true)"

# FIX (codex pre-commit, round 8): suite-like text inside a STRING is not a
# declaration either.
for src in 'const label = "it(";' "const label = 'describe(';" 'const label = `test(`;'; do
  R="$(fresh)"; rm "$R/smoke.test.ts"; printf 'import { it, describe, test } from "vitest";\n%s\nexport const a = 1;\n' "$src" > "$R/a.test.ts"
  out="$(run "$R" || true)"
  echo "$out" | grep -q "DRIFT.*no test file found" && ok "vitest: suite-like text in a string is not a suite ($src)" || bad "vitest: suite-like text in a string is not a suite ($src)" "$out"
done
# ...and a real declaration alongside such a string still counts
R="$(fresh)"; rm "$R/smoke.test.ts"; printf 'import { it } from "vitest";\nconst label = "it(";\nit(label, () => {});\n' > "$R/a.test.ts"
run "$R" >/dev/null && ok "vitest: a live declaration beside a suite-like string still counts" || bad "vitest: a live declaration beside a suite-like string still counts" "$(run "$R" || true)"

# FIX (codex pre-commit, round 15): a type-only import is ERASED by TypeScript,
# so the call under it is unbound at run time and vitest throws.
for imp in 'import type { it } from "vitest";' 'import { type it } from "vitest";'; do
  R="$(fresh)"; rm "$R/smoke.test.ts"
  printf '%s\nit("smoke", () => {});\n' "$imp" > "$R/a.test.ts"
  out="$(run "$R" || true)"
  echo "$out" | grep -q "DRIFT.*no test file found" && ok "vitest: a type-only import does not bind ($imp)" || bad "vitest: a type-only import does not bind ($imp)" "$out"
done

# Round 32 regression: ESM permits no whitespace at all around `from`. This
# already works — revealing the specifier turns its quotes into spaces, which
# supplies the separator — so lock the behaviour in rather than leave it
# accidental. (Codex read this as a defect; the run below says otherwise.)
R="$(fresh)"; rm "$R/smoke.test.ts"
printf 'import{it}from"vitest";it("smoke",()=>{});\n' > "$R/a.test.ts"
run "$R" >/dev/null && ok "vitest: a whitespace-free import still binds" || bad "vitest: a whitespace-free import still binds" "$(run "$R" || true)"

# FIX (codex pre-commit, round 29): an import written INSIDE a string literal is
# text, not an import — it binds nothing, so the bare call under it still throws.
R="$(fresh)"; rm "$R/smoke.test.ts"
printf 'const hint = %s;\nit("smoke", () => {});\n' "'import { it } from \"vitest\"'" > "$R/a.test.ts"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "vitest: an import quoted inside a string binds nothing" || bad "vitest: an import quoted inside a string binds nothing" "$out"

# FIX (codex pre-commit, round 13): a COMMENTED-OUT import binds nothing, so the
# bare call under it still throws. Imports are scanned with comments stripped
# (but strings kept — the import is identified by its "vitest" specifier).
R="$(fresh)"; rm "$R/smoke.test.ts"
printf '// import { it } from "vitest";\nit("smoke", () => {});\n' > "$R/a.test.ts"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "vitest: a commented-out import does not bind the bare call" || bad "vitest: a commented-out import does not bind the bare call" "$out"

# FIX (codex pre-commit, round 13): `as` may carry any whitespace, newlines
# included — a literal " as " split would report drift on a suite that runs.
R="$(fresh)"; rm "$R/smoke.test.ts"
printf 'import { test as\tscenario } from "vitest";\nscenario("smoke", () => {});\n' > "$R/a.test.ts"
run "$R" >/dev/null && ok "vitest: a tab-separated import alias counts" || bad "vitest: a tab-separated import alias counts" "$(run "$R" || true)"
R="$(fresh)"; rm "$R/smoke.test.ts"
printf 'import {\n  test as scenario,\n} from "vitest";\nscenario("smoke", () => {});\n' > "$R/a.test.ts"
run "$R" >/dev/null && ok "vitest: a multi-line import alias counts" || bad "vitest: a multi-line import alias counts" "$(run "$R" || true)"

# FIX (codex pre-commit, round 12): vitest's `globals` default is FALSE, so a
# bare `it(...)` with no import throws "it is not defined" — still a red
# validate, and it was what this gate's own suggested snippet used to recommend.
R="$(fresh)"; rm "$R/smoke.test.ts"; printf 'it("smoke", () => {});\n' > "$R/a.test.ts"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "vitest: a bare global with no import is not a runnable suite" || bad "vitest: a bare global with no import is not a runnable suite" "$out"
# ...unless the repo turns globals on, in which case the bare form really runs
R="$(fresh)"; rm "$R/smoke.test.ts"; printf 'it("smoke", () => {});\n' > "$R/a.test.ts"
printf 'export default { test: { globals: true } };\n' > "$R/vitest.config.ts"
run "$R" >/dev/null && ok "vitest: globals:true makes the bare form count" || bad "vitest: globals:true makes the bare form count" "$(run "$R" || true)"
# ...and globals:false spelled out is still the default answer
R="$(fresh)"; rm "$R/smoke.test.ts"; printf 'it("smoke", () => {});\n' > "$R/a.test.ts"
printf 'export default { test: { globals: false } };\n' > "$R/vitest.config.ts"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "vitest: globals:false leaves the bare form uncounted" || bad "vitest: globals:false leaves the bare form uncounted" "$out"

# FIX (codex pre-commit, round 9): vitest's API can be imported under a local
# name. That file runs, so reporting drift on it would block a valid repo.
R="$(fresh)"; rm "$R/smoke.test.ts"
printf 'import { test as scenario } from "vitest";\nscenario("smoke", () => {});\n' > "$R/a.test.ts"
run "$R" >/dev/null && ok "vitest: an aliased declaration import counts" || bad "vitest: an aliased declaration import counts" "$(run "$R" || true)"
# ...but the alias only counts when it renames a real declaration API
R="$(fresh)"; rm "$R/smoke.test.ts"
printf 'import { expect as scenario } from "vitest";\nscenario("smoke");\n' > "$R/a.test.ts"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "vitest: an alias of a non-declaration API is not a suite" || bad "vitest: an alias of a non-declaration API is not a suite" "$out"

# FIX (codex pre-commit, round 10): a namespace import is a valid, collected
# suite too — and the leading [^.\w] that rejects `re.test(x)` would reject it,
# so the qualified form needs its own alternative.
R="$(fresh)"; rm "$R/smoke.test.ts"
printf 'import * as vitest from "vitest";\nvitest.it("smoke", () => {});\n' > "$R/a.test.ts"
run "$R" >/dev/null && ok "vitest: a namespace-qualified declaration counts" || bad "vitest: a namespace-qualified declaration counts" "$(run "$R" || true)"
# ...but a qualified call on an UNRELATED namespace is still not a declaration.
# The file must ALSO carry a vitest namespace import, or the qualified branch is
# never built and this case would pass without exercising anything (found by
# break-probe: widening the branch to any \w+ left the suite green).
R="$(fresh)"; rm "$R/smoke.test.ts"
printf 'import * as vitest from "vitest";\nimport * as helpers from "./helpers";\nhelpers.it("smoke", () => {});\n' > "$R/a.test.ts"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "vitest: a qualified call on a non-vitest namespace is not a suite" || bad "vitest: a qualified call on a non-vitest namespace is not a suite" "$out"

# FIX (codex pre-commit, round 10): comments and strings must be recognised in
# ONE string-aware pass. A "https://..." URL is an ordinary line in a test file,
# and a regex comment-strip that runs first eats the rest of that line — real
# declaration included — reporting drift on a repo that is perfectly fine.
R="$(fresh)"; rm "$R/smoke.test.ts"
printf 'import { it } from "vitest";\nconst url = "https://example.com"; it("smoke", () => {});\n' > "$R/a.test.ts"
run "$R" >/dev/null && ok "vitest: a // inside a string does not open a comment" || bad "vitest: a // inside a string does not open a comment" "$(run "$R" || true)"
# ...and the mirror: a quote inside a comment must not open a string, which
# would otherwise swallow the live declaration after it
R="$(fresh)"; rm "$R/smoke.test.ts"
printf 'import { it } from "vitest";\n// it works, don\x27t remove\nit("smoke", () => {});\n' > "$R/a.test.ts"
run "$R" >/dev/null && ok "vitest: a quote inside a comment does not open a string" || bad "vitest: a quote inside a comment does not open a string" "$(run "$R" || true)"

# FIX (codex pre-commit, round 27): only vitest's REAL modifiers count after the
# dot — `test.notARealModifier(...)` throws at run time, so it is not a suite.
R="$(fresh)"; rm "$R/smoke.test.ts"
printf 'import { test } from "vitest";\ntest.notARealModifier("x", () => {});\n' > "$R/a.test.ts"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "vitest: an unknown modifier is not a declaration" || bad "vitest: an unknown modifier is not a declaration" "$out"
for mod in skip only todo concurrent fails sequential shuffle; do
  R="$(fresh)"; rm "$R/smoke.test.ts"
  printf 'import { test } from "vitest";\ntest.%s("x", () => {});\n' "$mod" > "$R/a.test.ts"
  run "$R" >/dev/null && ok "vitest terminal modifier test.$mod counts" || bad "vitest terminal modifier test.$mod counts" "$(run "$R" || true)"
done

# FIX (codex pre-commit, round 28): a FACTORY modifier returns a test function
# and registers nothing until that result is called, so `test.each([1])` alone
# leaves the file with no suite — vitest fails it, and so must this.
for mod in 'each([1])' 'for([1])' 'runIf(true)' 'skipIf(false)'; do
  R="$(fresh)"; rm "$R/smoke.test.ts"
  printf 'import { test } from "vitest";\ntest.%s;\n' "$mod" > "$R/a.test.ts"
  out="$(run "$R" || true)"
  echo "$out" | grep -q "DRIFT.*no test file found" && ok "vitest factory test.$mod alone registers nothing" || bad "vitest factory test.$mod alone registers nothing" "$out"
  R="$(fresh)"; rm "$R/smoke.test.ts"
  printf 'import { test } from "vitest";\ntest.%s("x", () => {});\n' "$mod" > "$R/a.test.ts"
  run "$R" >/dev/null && ok "vitest factory test.$mod called counts" || bad "vitest factory test.$mod called counts" "$(run "$R" || true)"
done
# FIX (codex pre-commit, round 33): the documented TAGGED-TEMPLATE form. It only
# broke because deleting the template turned it into a bare factory call; the
# scan masks strings now instead of deleting them, so the shape survives.
R="$(fresh)"; rm "$R/smoke.test.ts"
printf 'import { test } from "vitest";\ntest.each`\n  a | b\n  ${1} | ${2}\n`("adds", ({ a, b }) => {});\n' > "$R/a.test.ts"
run "$R" >/dev/null && ok "vitest: a tagged-template each counts" || bad "vitest: a tagged-template each counts" "$(run "$R" || true)"
# ...but the template alone still registers nothing
R="$(fresh)"; rm "$R/smoke.test.ts"
printf 'import { test } from "vitest";\ntest.each`\n  a | b\n`;\n' > "$R/a.test.ts"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "vitest: a tagged-template each never called registers nothing" || bad "vitest: a tagged-template each never called registers nothing" "$out"

# ...multi-line each-tables are the ordinary shape and must still be found
R="$(fresh)"; rm "$R/smoke.test.ts"
printf 'import { test } from "vitest";\ntest.each([\n  [1],\n  [2],\n])("adds %%i", (n) => {});\n' > "$R/a.test.ts"
run "$R" >/dev/null && ok "vitest: a multi-line each-table counts" || bad "vitest: a multi-line each-table counts" "$(run "$R" || true)"

# extend hands the API to a NEW name; the suite is written against that name
R="$(fresh)"; rm "$R/smoke.test.ts"
printf 'import { test } from "vitest";\nconst myTest = test.extend({});\nmyTest("x", () => {});\n' > "$R/a.test.ts"
run "$R" >/dev/null && ok "vitest: a test.extend binding counts when called" || bad "vitest: a test.extend binding counts when called" "$(run "$R" || true)"
R="$(fresh)"; rm "$R/smoke.test.ts"
printf 'import { test } from "vitest";\nconst myTest = test.extend({});\nexport default myTest;\n' > "$R/a.test.ts"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "vitest: a test.extend binding never called registers nothing" || bad "vitest: a test.extend binding never called registers nothing" "$out"

# a METHOD call that merely ends in .test( is not a declaration
R="$(fresh)"; rm "$R/smoke.test.ts"; printf 'import { test } from "vitest";\nexport const r = /x/;\nexport const b = r.test("x");\n' > "$R/a.test.ts"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "vitest: a regex .test() call is not a suite declaration" || bad "vitest: a regex .test() call is not a suite declaration" "$out"

# FIX (codex pre-commit, round 11): a repo that configures its runner's
# collection away from the defaults gets an explicit hand-off, not a guess —
# claiming "no test file found" would BLOCK a repo whose suite runs fine.
R="$(fresh)"; rm "$R/smoke.test.ts"
printf 'export default { test: { include: ["**/*.check.ts"] } };\n' > "$R/vitest.config.ts"
printf 'import { it } from "vitest";\nit("smoke", () => {});\n' > "$R/smoke.check.ts"
out="$(run "$R" || true)"
run "$R" >/dev/null && ok "a custom vitest include hands the check off instead of blocking" || bad "a custom vitest include hands the check off instead of blocking" "$out"
echo "$out" | grep -q "note: vitest.config.ts declares its own test collection" && ok "the hand-off says so on stderr rather than passing silently" || bad "the hand-off says so on stderr rather than passing silently" "$out"

# ...but an `include` that is NOT under a test block (optimizeDeps, say) says
# nothing about collection and must not wave the check aside
R="$(fresh)"; rm "$R/smoke.test.ts"
printf 'export default { optimizeDeps: { include: ["react"] } };\n' > "$R/vite.config.ts"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "a non-test include does not wave the check aside" || bad "a non-test include does not wave the check aside" "$out"

# FIX (codex pre-commit, round 15): vite.config.* sorts BEFORE vitest.config.*,
# so stopping at the first config found would miss the settings in the later one
# and reject a repo that collects fine.
R="$(fresh)"; rm "$R/smoke.test.ts"
printf 'export default { plugins: [] };\n' > "$R/vite.config.ts"
printf 'export default { test: { include: ["**/*.check.ts"] } };\n' > "$R/vitest.config.ts"
printf 'import { it } from "vitest";\nit("smoke", () => {});\n' > "$R/smoke.check.ts"
out="$(run "$R" || true)"
echo "$out" | grep -q "note: vitest.config.ts declares its own test collection" && ok "the config scan looks past a vite.config with no test block" || bad "the config scan looks past a vite.config with no test block" "$out"

# FIX (codex pre-commit, round 18): ...and past one that HAS a test block but
# only sets globals — vitest uses the dedicated config, so its include must
# still be seen.
R="$(fresh)"; rm "$R/smoke.test.ts"
printf 'export default { test: { globals: true } };\n' > "$R/vite.config.ts"
printf 'export default { test: { include: ["**/*.check.ts"] } };\n' > "$R/vitest.config.ts"
printf 'import { it } from "vitest";\nit("smoke", () => {});\n' > "$R/smoke.check.ts"
out="$(run "$R" || true)"
echo "$out" | grep -q "note: vitest.config.ts declares its own test collection" && ok "the config scan looks past a globals-only test block" || bad "the config scan looks past a globals-only test block" "$out"

# ...but globals is NOT unioned (FIX, codex pre-commit round 19): vitest gives
# the dedicated config precedence rather than merging, and globals decides
# whether a bare it(...) is bound — the accept direction, so precedence rules.
R="$(fresh)"; rm "$R/smoke.test.ts"; printf 'it("smoke", () => {});\n' > "$R/a.test.ts"
printf 'export default { test: { globals: true } };\n' > "$R/vite.config.ts"
run "$R" >/dev/null && ok "globals:true in a lone vite.config counts" || bad "globals:true in a lone vite.config counts" "$(run "$R" || true)"
printf 'export default { test: { environment: "node" } };\n' > "$R/vitest.config.ts"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "a dedicated vitest.config overrides vite.config's globals" || bad "a dedicated vitest.config overrides vite.config's globals" "$out"

# FIX (codex pre-commit, round 14): `exclude` and `dir` change collection just
# as much as `include` — an exclude can drop the very file this scan found.
# includeSource (FIX, codex pre-commit round 20) is the sharpest case: in-source
# tests live behind `import.meta.vitest` inside ordinary source files, so a
# perfectly valid repo has NO *.test.* filename at all.
for key in 'exclude: ["**/*.test.ts"]' 'dir: "tests"' 'includeSource: ["src/**/*.ts"]'; do
  R="$(fresh)"   # smoke.test.ts kept: under these settings vitest may not collect it
  printf 'export default { test: { %s } };\n' "$key" > "$R/vitest.config.ts"
  out="$(run "$R" || true)"
  echo "$out" | grep -q "note: vitest.config.ts declares its own test collection" && ok "a custom test.$key hands the check off" || bad "a custom test.$key hands the check off" "$out"
done

# FIX (codex pre-commit, round 22): a JS object may QUOTE its keys, and the
# earlier design stripped string literals before looking — erasing the very key
# names it was looking for.
for cfg in 'export default { test: { "include": ["**/*.check.ts"] } };' \
           'export default { "test": { include: ["**/*.check.ts"] } };' \
           "export default { test: { 'include': ['**/*.check.ts'] } };"; do
  R="$(fresh)"; rm "$R/smoke.test.ts"
  printf '%s\n' "$cfg" > "$R/vitest.config.ts"
  out="$(run "$R" || true)"
  echo "$out" | grep -q "note: vitest.config.ts declares its own test collection" && ok "a quoted collection key hands the check off: $cfg" || bad "a quoted collection key hands the check off: $cfg" "$out"
done
# ...and a quoted globals key binds the bare form
R="$(fresh)"; rm "$R/smoke.test.ts"; printf 'it("smoke", () => {});\n' > "$R/a.test.ts"
printf 'export default { test: { "globals": true } };\n' > "$R/vitest.config.ts"
run "$R" >/dev/null && ok "a quoted globals key counts" || bad "a quoted globals key counts" "$(run "$R" || true)"

# FIX (codex pre-commit, round 31): only the EXPORTED object is vitest's config.
# A `test: { … }` in an unrelated object earlier in the file configures nothing.
R="$(fresh)"; rm "$R/smoke.test.ts"
printf 'const metadata = { test: { include: [] } };\nexport default { plugins: [] };\n' > "$R/vitest.config.ts"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "a test block outside the exported config is not a config" || bad "a test block outside the exported config is not a config" "$out"
# ...and the ordinary defineConfig wrapper still reads as a literal
R="$(fresh)"; rm "$R/smoke.test.ts"
printf 'import { defineConfig } from "vitest/config";\nexport default defineConfig({ test: { include: ["**/*.check.ts"] } });\n' > "$R/vitest.config.ts"
out="$(run "$R" || true)"
echo "$out" | grep -q "note: vitest.config.ts declares its own test collection" && ok "export default defineConfig({...}) is read as a literal config" || bad "export default defineConfig({...}) is read as a literal config" "$out"
# ...and a defineConfig with NO test key must stay a literal, not read as opaque:
# unpeeled, the wrapper call would look like an identifier and hand off on
# nothing (found by break-probe — the case above passes either way).
R="$(fresh)"; rm "$R/smoke.test.ts"
printf 'import { defineConfig } from "vitest/config";\nexport default defineConfig({ plugins: [] });\n' > "$R/vitest.config.ts"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "a defineConfig with no test key is still a literal config" || bad "a defineConfig with no test key is still a literal config" "$out"
# ...while exporting an IDENTIFIER is the indirect case: unevaluable, hand off
R="$(fresh)"; rm "$R/smoke.test.ts"
printf 'const config = { test: { include: ["**/*.check.ts"] } };\nexport default config;\n' > "$R/vitest.config.ts"
out="$(run "$R" || true)"
echo "$out" | grep -q "note: vitest.config.ts declares its own test collection" && ok "exporting an identifier hands the check off rather than blocking" || bad "exporting an identifier hands the check off rather than blocking" "$out"

# FIX (codex pre-commit, round 30): only the filenames vitest ACTUALLY resolves
# count as configs. A prefix match would take `vite.config.backup` for one —
# vitest ignores that file, collects by its defaults, and the repo stays red.
for f in vite.config.backup vitest.config.txt vitest.config.ts.bak; do
  R="$(fresh)"; rm "$R/smoke.test.ts"
  printf 'export default { test: { include: ["**/*.check.ts"] } };\n' > "$R/$f"
  out="$(run "$R" || true)"
  echo "$out" | grep -q "DRIFT.*no test file found" && ok "$f is not a vitest config" || bad "$f is not a vitest config" "$out"
done
# ...and every extension vitest does resolve is honoured
for f in vitest.config.mts vitest.config.cjs vite.config.js vitest.workspace.ts; do
  R="$(fresh)"; rm "$R/smoke.test.ts"
  printf 'export default { test: { include: ["**/*.check.ts"] } };\n' > "$R/$f"
  out="$(run "$R" || true)"
  echo "$out" | grep -q "note: $f declares its own test collection" && ok "$f is a vitest config" || bad "$f is a vitest config" "$out"
done

# FIX (codex pre-commit, round 26): a `test` config reached through an
# identifier or a shorthand property is unevaluable — its settings live where
# nothing static can follow — so it hands off rather than having the defaults
# enforced on it.
for cfg in 'const test = { include: ["**/*.check.ts"] };
export default { test };' \
           'export default { test: myTestConfig };'; do
  R="$(fresh)"; rm "$R/smoke.test.ts"
  printf '%s\n' "$cfg" > "$R/vitest.config.ts"
  printf 'import { it } from "vitest";\nit("smoke", () => {});\n' > "$R/smoke.check.ts"
  out="$(run "$R" || true)"
  echo "$out" | grep -q "note: vitest.config.ts declares its own test collection" && ok "an indirect test config hands the check off" || bad "an indirect test config hands the check off" "$out"
done
# ...but a config that never mentions `test` is not indirect, it is just a config
R="$(fresh)"; rm "$R/smoke.test.ts"
printf 'export default { plugins: [], optimizeDeps: { include: ["react"] } };\n' > "$R/vite.config.ts"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "a config with no test property is not indirect" || bad "a config with no test property is not indirect" "$out"

# FIX (codex pre-commit, round 24): keeping the strings also meant a `test: {`
# sitting inside an ordinary string VALUE looked like a real config, handing the
# check off on a repo vitest still collects by default. The block is now found
# on a string-masked copy and sliced out of the unmasked one.
R="$(fresh)"; rm "$R/smoke.test.ts"
printf 'export default { label: "test: { include: [] }" };\n' > "$R/vitest.config.ts"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "a test block inside a string value is not a config" || bad "a test block inside a string value is not a config" "$out"

# ...and keeping the strings means the brace count must skip them: a `{` inside
# a string value would otherwise over-extend the test block and pull an
# unrelated optimizeDeps.include into it, waving the check aside on nothing.
R="$(fresh)"; rm "$R/smoke.test.ts"
printf 'export default { test: { name: "{" }, optimizeDeps: { include: ["react"] } };\n' > "$R/vite.config.ts"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "a brace inside a string does not over-extend the test block" || bad "a brace inside a string does not over-extend the test block" "$out"

# FIX (codex pre-commit, round 12): ...and neither does one that merely FOLLOWS
# an empty test block. Searching everything after `test: {}` would find the
# unrelated key further down the file; the search is brace-scoped to the block.
R="$(fresh)"; rm "$R/smoke.test.ts"
printf 'export default { test: {}, optimizeDeps: { include: ["react"] } };\n' > "$R/vite.config.ts"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "an include after an empty test block does not wave the check aside" || bad "an include after an empty test block does not wave the check aside" "$out"

# same hand-off on python, driven by pytest's own config keys
printf '[tool.pytest.ini_options]\npython_files = ["check_*.py"]\n' > "$PYR/pyproject.toml"
rm "$PYR/test_smoke.py"
run "$PYR" >/dev/null && ok "a custom pytest python_files hands the check off" || bad "a custom pytest python_files hands the check off" "$(run "$PYR" || true)"
# ...and a pyproject with no collection keys does not
printf '[tool.ruff]\nline-length = 100\n' > "$PYR/pyproject.toml"
out="$(run "$PYR" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "a pyproject without collection keys does not wave the check aside" || bad "a pyproject without collection keys does not wave the check aside" "$out"

# FIX (codex pre-commit, round 15): the key must be in the file's OWN pytest
# section and not commented out — otherwise the hand-off becomes a bypass.
printf '[tool.ruff]\npython_files = ["check_*.py"]\n' > "$PYR/pyproject.toml"
out="$(run "$PYR" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "a collection key in an unrelated section does not wave the check aside" || bad "a collection key in an unrelated section does not wave the check aside" "$out"
printf '[tool.pytest.ini_options]\n# python_files = ["check_*.py"]\n' > "$PYR/pyproject.toml"
out="$(run "$PYR" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "a COMMENTED collection key does not wave the check aside" || bad "a COMMENTED collection key does not wave the check aside" "$out"
# ...and pytest.ini's own section name is honoured
printf '[pytest]\ntestpaths = suites\n' > "$PYR/pytest.ini"
run "$PYR" >/dev/null && ok "pytest.ini [pytest] testpaths hands the check off" || bad "pytest.ini [pytest] testpaths hands the check off" "$(run "$PYR" || true)"
# FIX (codex pre-commit, round 16): norecursedirs can hide the very directory
# the scan found a test in, so it changes collection just as much.
printf '[pytest]\nnorecursedirs = tests\n' > "$PYR/pytest.ini"
run "$PYR" >/dev/null && ok "pytest.ini norecursedirs hands the check off" || bad "pytest.ini norecursedirs hands the check off" "$(run "$PYR" || true)"
# FIX (codex pre-commit, round 23): addopts can carry --ignore/--deselect/-k/-m,
# each of which can reduce collection to nothing while a matching file sits
# right there. Treated conservatively: any addopts hands off.
printf '[pytest]\naddopts = --ignore=tests\n' > "$PYR/pytest.ini"
run "$PYR" >/dev/null && ok "pytest addopts hands the check off" || bad "pytest addopts hands the check off" "$(run "$PYR" || true)"
rm "$PYR/pytest.ini"

# FIX (codex pre-commit, round 22): pytest's INI parser takes `:` as a delimiter
# too, and TOML permits a quoted key — miss either and a real override reads as
# absent, so the gate enforces defaults on a repo that legitimately moved.
printf '[pytest]\npython_files: check_*.py\n' > "$PYR/pytest.ini"
run "$PYR" >/dev/null && ok "a colon-delimited pytest key hands the check off" || bad "a colon-delimited pytest key hands the check off" "$(run "$PYR" || true)"
rm "$PYR/pytest.ini"
printf '[tool.pytest.ini_options]\n"python_files" = ["check_*.py"]\n' > "$PYR/pyproject.toml"
run "$PYR" >/dev/null && ok "a quoted TOML pytest key hands the check off" || bad "a quoted TOML pytest key hands the check off" "$(run "$PYR" || true)"

rm "$PYR/pyproject.toml"; printf 'def test_smoke():\n    assert True\n' > "$PYR/test_smoke.py"

# a test file in an excluded directory must not satisfy the gate. .quality-kit-src
# is the load-bearing one: quality.yml clones the kit INSIDE the repo before this
# gate runs, and v0.4.1 exists because that directory kept getting scanned.
for d in node_modules dist .quality-kit-src; do
  R="$(fresh)"; rm "$R/smoke.test.ts"
  mkdir -p "$R/$d"; printf 'import { it } from "vitest";\nit("smoke", () => {});\n' > "$R/$d/a.test.ts"
  out="$(run "$R" || true)"
  echo "$out" | grep -q "DRIFT.*no test file found" && ok "a test file only in $d does not satisfy the gate" || bad "a test file only in $d does not satisfy the gate" "$out"
done

# python's validate chain has the same property — pytest exits 5 on an empty
# collection and make propagates it — so the gate applies there, with pytest's
# own collection rules (test_*.py / *_test.py) rather than vitest's.
rm "$PYR/test_smoke.py"
out="$(run "$PYR" || true)"
echo "$out" | grep -q "DRIFT.*no test file found.*pytest" && ok "python repo with no test file caught" || bad "python repo with no test file caught" "$out"
printf 'def smoke():\n    return True\n' > "$PYR/smoke.py"
out="$(run "$PYR" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "pytest does not collect smoke.py — not a test file" || bad "pytest does not collect smoke.py — not a test file" "$out"
rm "$PYR/smoke.py"; printf 'def test_x():\n    assert True\n' > "$PYR/foo_test.py"
run "$PYR" >/dev/null && ok "pytest collects foo_test.py — counts as a test file" || bad "pytest collects foo_test.py — counts as a test file" "$(run "$PYR" || true)"

# FIX (codex pre-commit): on pytest the FILENAME is not enough. pytest imports a
# matching module and still reports "no tests ran" (exit 5) when it declares no
# test item — the exact day-one failure this gate exists to catch — so a helper
# named test_helpers.py must not satisfy it. (Vitest is not the same case: it
# collects a matching file and fails it by name, so the ts arm stops at the
# filename; the ts fixtures deliberately carry no test call.)
rm "$PYR/foo_test.py"; printf 'HELPERS = 1\n\n\ndef make_fixture():\n    return HELPERS\n' > "$PYR/test_helpers.py"
out="$(run "$PYR" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "pytest: a matching filename with no test item does not satisfy the gate" || bad "pytest: a matching filename with no test item does not satisfy the gate" "$out"
printf 'class TestThing:\n    def test_x(self):\n        assert True\n' > "$PYR/test_helpers.py"
run "$PYR" >/dev/null && ok "pytest collects a class Test* — counts as a test file" || bad "pytest collects a class Test* — counts as a test file" "$(run "$PYR" || true)"

# FIX (codex pre-commit, round 2): a Test* CLASS is not by itself a collectable
# item — pytest still needs a test* method inside it, so `class TestHelpers: pass`
# collects zero and exits 5. Matching python_functions (which finds the indented
# method too) is both simpler and correct; a separate python_classes branch would
# pass this fixture.
printf 'class TestHelpers:\n    pass\n' > "$PYR/test_helpers.py"
out="$(run "$PYR" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "pytest: a Test* class with no test method does not satisfy the gate" || bad "pytest: a Test* class with no test method does not satisfy the gate" "$out"

# FIX (codex pre-commit, round 3): ...and the mirror case — a test* method on a
# plain (non-Test*) class is not collected either. Only the ast knows the
# difference; any regex over the file text gets one of these two wrong.
printf 'class Helpers:\n    def test_x(self):\n        assert True\n' > "$PYR/test_helpers.py"
out="$(run "$PYR" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "pytest: a test method on a non-Test class does not satisfy the gate" || bad "pytest: a test method on a non-Test class does not satisfy the gate" "$out"

# a nested def test_x inside a top-level function is not an item either
printf 'def helper():\n    def test_x():\n        assert True\n    return test_x\n' > "$PYR/test_helpers.py"
out="$(run "$PYR" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "pytest: a nested test function does not satisfy the gate" || bad "pytest: a nested test function does not satisfy the gate" "$out"

# a top-level async test IS an item (pytest plugins collect it; pytest's own
# collector matches the name either way)
printf 'async def test_x():\n    assert True\n' > "$PYR/test_helpers.py"
run "$PYR" >/dev/null && ok "pytest collects a top-level async test" || bad "pytest collects a top-level async test" "$(run "$PYR" || true)"

# FIX (codex pre-commit, round 4): pytest's unittest integration collects ANY
# unittest.TestCase subclass in a collected module — python_classes does not
# govern it — so a `class SmokeTest(unittest.TestCase)` must not be reported as
# drift just because its name does not start with Test.
printf 'import unittest\n\n\nclass SmokeTest(unittest.TestCase):\n    def test_x(self):\n        assert True\n' > "$PYR/test_helpers.py"
run "$PYR" >/dev/null && ok "pytest collects a unittest.TestCase subclass named Smoke*" || bad "pytest collects a unittest.TestCase subclass named Smoke*" "$(run "$PYR" || true)"
printf 'from unittest import TestCase\n\n\nclass SmokeTest(TestCase):\n    def test_x(self):\n        assert True\n' > "$PYR/test_helpers.py"
run "$PYR" >/dev/null && ok "pytest collects a bare-imported TestCase subclass" || bad "pytest collects a bare-imported TestCase subclass" "$(run "$PYR" || true)"
# ...but the item requirement still holds: a TestCase subclass with no test method
printf 'import unittest\n\n\nclass SmokeTest(unittest.TestCase):\n    pass\n' > "$PYR/test_helpers.py"
out="$(run "$PYR" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "a TestCase subclass with no test method does not satisfy the gate" || bad "a TestCase subclass with no test method does not satisfy the gate" "$out"

# FIX (codex pre-commit, round 5): pytest REFUSES to collect a Test* class that
# defines a constructor — it warns and collects nothing — so such a class is not
# evidence of a test, however many test_* methods it carries.
for ctor in __init__ __new__; do
  printf 'class TestSmoke:\n    def %s(self):\n        pass\n\n    def test_x(self):\n        assert True\n' "$ctor" > "$PYR/test_helpers.py"
  out="$(run "$PYR" || true)"
  echo "$out" | grep -q "DRIFT.*no test file found" && ok "a Test* class with a $ctor does not satisfy the gate" || bad "a Test* class with a $ctor does not satisfy the gate" "$out"
done
# ...but the constructor exclusion does NOT apply to unittest.TestCase subclasses:
# TestCase defines its own __init__ and pytest collects them anyway
printf 'import unittest\n\n\nclass TestSmoke(unittest.TestCase):\n    def __init__(self, *a):\n        super().__init__(*a)\n\n    def test_x(self):\n        assert True\n' > "$PYR/test_helpers.py"
run "$PYR" >/dev/null && ok "the constructor exclusion does not apply to TestCase subclasses" || bad "the constructor exclusion does not apply to TestCase subclasses" "$(run "$PYR" || true)"

# FIX (codex pre-commit, round 6): pytest follows inheritance — a class whose
# TestCase base is itself declared in the same module is still collected, so
# recognising only a DIRECT TestCase base would report drift on a valid suite.
printf 'import unittest\n\n\nclass Base(unittest.TestCase):\n    pass\n\n\nclass Smoke(Base):\n    def test_x(self):\n        assert True\n' > "$PYR/test_helpers.py"
run "$PYR" >/dev/null && ok "pytest collects an indirect TestCase subclass" || bad "pytest collects an indirect TestCase subclass" "$(run "$PYR" || true)"
# ...but an unrelated same-module base chain is still not collectable
printf 'class Base:\n    pass\n\n\nclass Smoke(Base):\n    def test_x(self):\n        assert True\n' > "$PYR/test_helpers.py"
out="$(run "$PYR" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "a non-TestCase base chain does not satisfy the gate" || bad "a non-TestCase base chain does not satisfy the gate" "$out"

# FIX (codex pre-commit, round 7): pytest collects an INHERITED test_* method,
# and equally refuses a class whose __init__ is inherited — so neither question
# may stop at the class's own body.
printf 'class Base:\n    def test_x(self):\n        assert True\n\n\nclass TestSmoke(Base):\n    pass\n' > "$PYR/test_helpers.py"
run "$PYR" >/dev/null && ok "pytest collects a test method inherited from a same-module base" || bad "pytest collects a test method inherited from a same-module base" "$(run "$PYR" || true)"
printf 'class Base:\n    def __init__(self):\n        pass\n\n\nclass TestSmoke(Base):\n    def test_x(self):\n        assert True\n' > "$PYR/test_helpers.py"
out="$(run "$PYR" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "a Test* class with an INHERITED constructor does not satisfy the gate" || bad "a Test* class with an INHERITED constructor does not satisfy the gate" "$out"

# FIX (codex pre-commit, round 9): "TestCase" is resolved from the module's own
# imports, not guessed from a name suffix — a local class merely NAMED
# FauxTestCase is not a unittest.TestCase and pytest collects nothing from it.
printf 'class FauxTestCase:\n    def test_x(self):\n        assert True\n\n\nclass Smoke(FauxTestCase):\n    pass\n' > "$PYR/test_helpers.py"
out="$(run "$PYR" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "a class merely NAMED *TestCase is not a unittest base" || bad "a class merely NAMED *TestCase is not a unittest base" "$out"
# ...and an aliased unittest import still resolves
printf 'from unittest import TestCase as TC\n\n\nclass Smoke(TC):\n    def test_x(self):\n        assert True\n' > "$PYR/test_helpers.py"
run "$PYR" >/dev/null && ok "an aliased unittest.TestCase import still resolves" || bad "an aliased unittest.TestCase import still resolves" "$(run "$PYR" || true)"
printf 'import unittest as ut\n\n\nclass Smoke(ut.TestCase):\n    def test_x(self):\n        assert True\n' > "$PYR/test_helpers.py"
run "$PYR" >/dev/null && ok "an aliased unittest module import still resolves" || bad "an aliased unittest module import still resolves" "$(run "$PYR" || true)"

# FIX (codex pre-commit, round 29): a FIXTURE named test_* is still a fixture —
# pytest excludes it from collection, so it cannot be the repo's only test.
printf 'import pytest\n\n\n@pytest.fixture\ndef test_client():\n    return 1\n' > "$PYR/test_helpers.py"
out="$(run "$PYR" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "a @pytest.fixture named test_* is not a test item" || bad "a @pytest.fixture named test_* is not a test item" "$out"
printf 'from pytest import fixture\n\n\n@fixture()\ndef test_client():\n    return 1\n' > "$PYR/test_helpers.py"
out="$(run "$PYR" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "a bare @fixture() named test_* is not a test item" || bad "a bare @fixture() named test_* is not a test item" "$out"
# ...but an ordinary decorator does not disqualify a real test
printf 'import pytest\n\n\n@pytest.mark.parametrize("x", [1])\ndef test_x(x):\n    assert x\n' > "$PYR/test_helpers.py"
run "$PYR" >/dev/null && ok "a @pytest.mark decorator does not disqualify a test" || bad "a @pytest.mark decorator does not disqualify a test" "$(run "$PYR" || true)"

# FIX (codex pre-commit, round 29): a function-level `__test__ = False` disables
# that one item, and pytest reads the attribute at collection time.
printf 'def test_x():\n    assert True\n\n\ntest_x.__test__ = False\n' > "$PYR/test_helpers.py"
out="$(run "$PYR" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "a function opted out with test_x.__test__ = False is not an item" || bad "a function opted out with test_x.__test__ = False is not an item" "$out"
printf 'class TestSmoke:\n    def test_x(self):\n        assert True\n\n\nTestSmoke.__test__ = False\n' > "$PYR/test_helpers.py"
out="$(run "$PYR" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "a class opted out by attribute is not an item" || bad "a class opted out by attribute is not an item" "$out"
# FIX (codex pre-commit, round 32): the opt-out can sit in the CLASS body and
# disable that class's only method.
printf 'class TestSmoke:\n    def test_x(self):\n        assert True\n\n    test_x.__test__ = False\n' > "$PYR/test_helpers.py"
out="$(run "$PYR" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "a method opted out inside the class body is not an item" || bad "a method opted out inside the class body is not an item" "$out"
# ...and __test__ = True by attribute still collects
printf 'def test_x():\n    assert True\n\n\ntest_x.__test__ = True\n' > "$PYR/test_helpers.py"
run "$PYR" >/dev/null && ok "an attribute __test__ = True still collects" || bad "an attribute __test__ = True still collects" "$(run "$PYR" || true)"

# FIX (codex pre-commit, round 25): a base IMPORTED from another module may
# carry the test methods. Nothing static can see them, so "cannot tell" must not
# read as "no tests" — that would block a valid suite.
# FIX (codex pre-commit, round 27): and it must not count as evidence either —
# `Base` may declare nothing. Neither answer is knowable, so it hands OFF: the
# run is clean, and the note names the file.
printf 'from helpers import Base\n\n\nclass TestSmoke(Base):\n    pass\n' > "$PYR/test_helpers.py"
out="$(run "$PYR" || true)"
run "$PYR" >/dev/null && ok "a Test* class over an imported base does not block" || bad "a Test* class over an imported base does not block" "$out"
echo "$out" | grep -q "note: test_helpers.py declares a test class over a base imported" && ok "...and hands off by name rather than counting as a suite" || bad "...and hands off by name rather than counting as a suite" "$out"
# ...but a base this module CAN see is judged on its real contents
printf 'class Base:\n    pass\n\n\nclass TestSmoke(Base):\n    pass\n' > "$PYR/test_helpers.py"
out="$(run "$PYR" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "a Test* class over an empty same-module base does not count" || bad "a Test* class over an empty same-module base does not count" "$out"
# ...and an imported base does not rescue a class pytest would not collect anyway
printf 'from helpers import Base\n\n\nclass Smoke(Base):\n    pass\n' > "$PYR/test_helpers.py"
out="$(run "$PYR" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "an imported base does not make a non-Test* class collectable" || bad "an imported base does not make a non-Test* class collectable" "$out"

# FIX (codex pre-commit, round 19): `__test__ = False` is pytest's own opt-out —
# it collects nothing from that module or class, however many test_* names it
# carries, so such a file is not proof of a suite.
printf '__test__ = False\n\n\ndef test_x():\n    assert True\n' > "$PYR/test_helpers.py"
out="$(run "$PYR" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "a module opted out with __test__ = False is not a test file" || bad "a module opted out with __test__ = False is not a test file" "$out"
printf 'class TestSmoke:\n    __test__ = False\n\n    def test_x(self):\n        assert True\n' > "$PYR/test_helpers.py"
out="$(run "$PYR" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "a class opted out with __test__ = False is not a test item" || bad "a class opted out with __test__ = False is not a test item" "$out"
# ...and __test__ = True (or absent) still collects
printf '__test__ = True\n\n\ndef test_x():\n    assert True\n' > "$PYR/test_helpers.py"
run "$PYR" >/dev/null && ok "__test__ = True still collects" || bad "__test__ = True still collects" "$(run "$PYR" || true)"

# FIX (codex pre-commit, round 18): unittest.TestCase reached through a dotted
# module path, in every standard import form. Each of these is collected by
# pytest, so reporting drift on one would block a valid suite.
while IFS='|' read -r head base; do
  [ -n "$head" ] || continue
  printf '%s\n\n\nclass Smoke(%s):\n    def test_x(self):\n        assert True\n' "$head" "$base" > "$PYR/test_helpers.py"
  run "$PYR" >/dev/null && ok "unittest base form: $head -> $base" || bad "unittest base form: $head -> $base" "$(run "$PYR" || true)"
done <<'ROWS'
import unittest.case|unittest.case.TestCase
from unittest import case|case.TestCase
import unittest.case as uc|uc.TestCase
from unittest import case as c|c.TestCase
import unittest as ut|ut.case.TestCase
from unittest.case import TestCase|TestCase
ROWS
# ...and a dotted base that has nothing to do with unittest is still not one
printf 'import helpers\n\n\nclass Smoke(helpers.TestCase):\n    def test_x(self):\n        assert True\n' > "$PYR/test_helpers.py"
out="$(run "$PYR" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "a dotted non-unittest TestCase base is not a unittest base" || bad "a dotted non-unittest TestCase base is not a unittest base" "$out"

# FIX (codex pre-commit, round 6): {arch} is also in pytest's norecursedirs
rm "$PYR/test_helpers.py"; mkdir -p "$PYR/{arch}"
printf 'def test_smoke():\n    assert True\n' > "$PYR/{arch}/test_smoke.py"
out="$(run "$PYR" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "pytest does not recurse into {arch} — does not satisfy the gate" || bad "pytest does not recurse into {arch} — does not satisfy the gate" "$out"
rm -rf "$PYR/{arch}"

# FIX (codex pre-commit, round 4): `*.egg` is a GLOB in pytest's norecursedirs,
# so it cannot be a literal in the skip set — a repo whose only match sits under
# vendor.egg/ really does collect nothing.
mkdir -p "$PYR/vendor.egg"
printf 'def test_smoke():\n    assert True\n' > "$PYR/vendor.egg/test_smoke.py"
out="$(run "$PYR" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "pytest does not recurse into *.egg — does not satisfy the gate" || bad "pytest does not recurse into *.egg — does not satisfy the gate" "$out"
rm -rf "$PYR/vendor.egg"

# ...and .egg is a pytest rule only: vitest happily collects under vendor.egg/
R="$(fresh)"; rm "$R/smoke.test.ts"; mkdir -p "$R/vendor.egg"; printf 'import { it } from "vitest";\nit("smoke", () => {});\n' > "$R/vendor.egg/a.test.ts"
run "$R" >/dev/null && ok "the *.egg exclusion does not leak onto the ts profile" || bad "the *.egg exclusion does not leak onto the ts profile" "$(run "$R" || true)"

# FIX (codex pre-commit, round 3): the repo is untrusted input to this gate. A
# committed symlink named test_helpers.py pointing at /dev/zero must not be read
# — following it would hang the gate or exhaust its memory. `timeout` is the
# assertion here: a regression hangs rather than fails.
ln -s /dev/zero "$PYR/test_helpers.py"
out="$(timeout 30 env KIT_DIR="$KITROOT" bash "$CD" "$PYR" 2>&1 || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "pytest: a symlink to a special file is not read and does not satisfy the gate" || bad "pytest: a symlink to a special file is not read and does not satisfy the gate" "$out"
rm "$PYR/test_helpers.py"

# FIX (codex pre-commit): `cypress` is one of VITEST's default exclusions, not
# one of pytest's norecursedirs — unioning the two lists would reject a python
# repo whose cypress/test_smoke.py pytest really does collect.
mkdir -p "$PYR/cypress"
printf 'def test_smoke():\n    assert True\n' > "$PYR/cypress/test_smoke.py"
run "$PYR" >/dev/null && ok "python scan does not import vitest's cypress exclusion" || bad "python scan does not import vitest's cypress exclusion" "$(run "$PYR" || true)"
rm -rf "$PYR/cypress"

# ...while a ts repo keeps it: cypress IS a vitest default exclusion
R="$(fresh)"; rm "$R/smoke.test.ts"; mkdir -p "$R/cypress"; printf 'import { it } from "vitest";\nit("smoke", () => {});\n' > "$R/cypress/a.test.ts"
out="$(run "$R" || true)"
echo "$out" | grep -q "DRIFT.*no test file found" && ok "vitest excludes cypress on the ts profile" || bad "vitest excludes cypress on the ts profile" "$out"

# FIX (codex pre-commit, round 2): vitest's default exclude has a FILE-level arm
# too — **/{karma,rollup,webpack,…}.config.* — so a candidate excluded by name
# must not satisfy the gate however well it matches the include.
for f in webpack.config.test.ts vitest.config.spec.ts prettier.config.test.mts; do
  R="$(fresh)"; rm "$R/smoke.test.ts"; printf 'import { it } from "vitest";\nit("smoke", () => {});\n' > "$R/$f"
  out="$(run "$R" || true)"
  echo "$out" | grep -q "DRIFT.*no test file found" && ok "vitest excludes $f by name — does not satisfy the gate" || bad "vitest excludes $f by name — does not satisfy the gate" "$out"
done
# ...but only that exact prefix set: my.config.test.ts is NOT excluded
R="$(fresh)"; rm "$R/smoke.test.ts"; printf 'import { it } from "vitest";\nit("smoke", () => {});\n' > "$R/my.config.test.ts"
run "$R" >/dev/null && ok "a non-listed *.config.test.ts is still collected" || bad "a non-listed *.config.test.ts is still collected" "$(run "$R" || true)"

# ...and build/ is a pytest norecursedirs entry but NOT a vitest exclusion
R="$(fresh)"; rm "$R/smoke.test.ts"; mkdir -p "$R/build"; printf 'import { it } from "vitest";\nit("smoke", () => {});\n' > "$R/build/a.test.ts"
run "$R" >/dev/null && ok "vitest does not exclude build/ on the ts profile" || bad "vitest does not exclude build/ on the ts profile" "$(run "$R" || true)"

printf 'def test_smoke():\n    assert True\n' > "$PYR/test_smoke.py"

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
    && printf 'def test_smoke():\n    assert True\n' > test_smoke.py \
    && git add -A && git -c user.name=ci -c user.email=ci@example.com commit -q -m init)
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
