#!/usr/bin/env bash
# What: the canonical `validate:fast` script, run exactly as npm runs it (`/bin/sh -c` from the
#       repo root), against fixture repos and PATH stand-ins for npm and vitest.
#       Where: quality-kit/ts.
# Why:  `vitest run --changed` with no ref selects only UNCOMMITTED changes, so on a clean tree it
#       collects zero tests, prints `No test files found, exiting with code 0` and exits 0 — a
#       green validate:fast that tested nothing (#45). The script must fail loudly there and keep
#       today's behavior whenever the tree is dirty. Stand-ins, not the real toolchain: the
#       failure mode is vitest's zero-collection exit status, which a stand-in reproduces
#       exactly, and the suite then runs (and can never SKIP) on a box with no node at all.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
KITROOT="$(cd "$DIR/.." && pwd)"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }

OLD='npm run format:check && npm run lint && npm run typecheck && vitest run --changed'
PROFILES=(node nextjs vite)

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
# npm stand-in: `npm run <step>` exits with that step's FAKE_*_RC; anything else is recorded and
# refused, so an unexpected invocation can never read as a pass.
cat >"$T/bin/npm" <<'EOF'
#!/usr/bin/env bash
echo "npm $*" >> "$NPM_LOG"
case "$*" in
  "run format:check") exit "${FAKE_FORMAT_RC:-0}" ;;
  "run lint")         exit "${FAKE_LINT_RC:-0}" ;;
  "run typecheck")    exit "${FAKE_TYPECHECK_RC:-0}" ;;
esac
exit 97
EOF
# vitest stand-in, modelled on vitest 4.1.10: with no uncommitted path under src/, `run --changed`
# collects nothing, says so, and exits 0; otherwise it prints FAKE_VITEST_OUT, exits FAKE_VITEST_RC.
cat >"$T/bin/vitest" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$VITEST_LOG"
if [ -n "$FAKE_VITEST_ZERO" ]; then
  echo "No test files found, exiting with code 0"
  exit 0
fi
if [ -n "$(git status --porcelain --untracked-files=all -- src/)" ]; then
  printf '%s\n' "${FAKE_VITEST_OUT:-✓ src/sum.test.ts (1 test)}"
  exit "${FAKE_VITEST_RC:-0}"
fi
echo "No test files found, exiting with code 0"
exit 0
EOF
chmod +x "$T/bin/npm" "$T/bin/vitest"
export NPM_LOG="$T/npm.log" VITEST_LOG="$T/vitest.log"
export PATH="$T/bin:$PATH"

mk_fixture() { # → clean fixture repo (src/sum.ts, src/sum.test.ts, .gitignore, README.md); any failed step → rc 1, no path
  # Checked explicitly: callers run this inside $( ), where set -e does not reach.
  local r s; r="$(mktemp -d "$T/fx.XXXXXX")" || return 1
  (cd "$r" && git init -q && git config core.hooksPath /dev/null && mkdir src \
    && printf 'export const sum = (a: number, b: number) => a + b;\n' > src/sum.ts \
    && printf 'import { expect, it } from "vitest";\nimport { sum } from "./sum";\nit("sums", () => expect(sum(1, 2)).toBe(3));\n' > src/sum.test.ts \
    && printf 'node_modules/\n' > .gitignore && printf '# fixture\n' > README.md \
    && git add -A && git -c user.name=t -c user.email=t@t commit -q -m fixture) || return 1
  s="$(git -C "$r" status --porcelain --untracked-files=all)" || return 1
  [ -z "$s" ] || return 1
  echo "$r"
}
fixture() { # $1=var → $1 := mk_fixture; a build failure stops the suite here
  local r
  r=$(mk_fixture) || { echo "FAIL fixture repo was not built"; exit 1; }
  printf -v "$1" '%s' "$r"
}
run_fast() { # $1=repo $2=script [VAR=value...] → out, rc; the stand-in logs start empty
  : > "$NPM_LOG"; : > "$VITEST_LOG"
  set +e; out=$(cd "$1" && env "${@:3}" /bin/sh -c "$2" 2>&1); rc=$?; set -e
}
edit_sum() { printf 'export const two = 2;\n' >> "$1/src/sum.ts"; }
has()   { printf '%s\n' "$out" | grep -qF -- "$1"; }
no_tc() { ! printf '%s\n' "$out" | grep -qi 'no tests collected'; }

for p in "${PROFILES[@]}"; do
  FAST="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['validate:fast'])" "$DIR/package-scripts.$p.json")" \
    || { echo "FAIL $p: validate:fast could not be read from package-scripts.$p.json"; exit 1; }

  fixture R; run_fast "$R" "$FAST"
  [ "$rc" != 0 ] && ! no_tc && has 'npm run validate' && has '--changed' \
    && ok "$p: clean tree fails loudly, naming the remedy" \
    || bad "$p: clean tree fails loudly, naming the remedy" "rc=$rc out=$out"

  fixture R; mkdir -p "$R/node_modules/.cache" && echo x > "$R/node_modules/.cache/x"
  if [ -n "$(git -C "$R" status --porcelain --untracked-files=all)" ]; then
    bad "$p: ignored files do not make a clean tree look dirty" "fixture: node_modules/ is not ignored"
  else
    run_fast "$R" "$FAST"
    [ "$rc" != 0 ] && ! no_tc \
      && ok "$p: ignored files do not make a clean tree look dirty" \
      || bad "$p: ignored files do not make a clean tree look dirty" "rc=$rc out=$out"
  fi

  fixture R; edit_sum "$R"; run_fast "$R" "$FAST"
  [ "$rc" = 0 ] && has '✓ src/sum.test.ts (1 test)' && no_tc && [ "$(cat "$VITEST_LOG")" = 'run --changed' ] \
    && ok "$p: unstaged edit runs vitest run --changed (no ref) and passes" \
    || bad "$p: unstaged edit runs vitest run --changed (no ref) and passes" "rc=$rc vitest=$(cat "$VITEST_LOG") out=$out"

  fixture R; edit_sum "$R"; git -C "$R" add src/sum.ts; run_fast "$R" "$FAST"
  [ "$rc" = 0 ] && no_tc \
    && ok "$p: staged-only edit passes" \
    || bad "$p: staged-only edit passes" "rc=$rc out=$out"

  fixture R; edit_sum "$R"; run_fast "$R" "$FAST" FAKE_VITEST_OUT='FAIL src/sum.test.ts' FAKE_VITEST_RC=1
  [ "$rc" != 0 ] && has 'FAIL src/sum.test.ts' && no_tc \
    && ok "$p: failing covered test still fails, without the zero-collection message" \
    || bad "$p: failing covered test still fails, without the zero-collection message" "rc=$rc out=$out"

  fixture R; echo more >> "$R/README.md"; run_fast "$R" "$FAST"
  [ "$rc" = 0 ] \
    && ok "$p: uncommitted docs-only change is not blocked" \
    || bad "$p: uncommitted docs-only change is not blocked" "rc=$rc out=$out"

  fixture R; edit_sum "$R"; run_fast "$R" "$FAST" FAKE_LINT_RC=1
  [ "$rc" != 0 ] && [ ! -s "$VITEST_LOG" ] \
    && ok "$p: lint failure short-circuits the test step" \
    || bad "$p: lint failure short-circuits the test step" "rc=$rc vitest=$(cat "$VITEST_LOG")"

  fixture R; edit_sum "$R"; run_fast "$R" "$FAST" FAKE_VITEST_ZERO=1
  [ "$rc" = 0 ] && has 'No test files found, exiting with code 0' && no_tc \
    && ok "$p: an uncommitted source edit that collects zero tests keeps today's --changed behavior" \
    || bad "$p: an uncommitted source edit that collects zero tests keeps today's --changed behavior" "rc=$rc out=$out"
done

# --- the three canonical JSONs: validate:fast agrees, every other key is as at eb55a39 ---
if msg="$(python3 - "$DIR" "$OLD" <<'EOF'
import json, sys
d, old = sys.argv[1], sys.argv[2]
common = {"format": "oxfmt", "format:check": "oxfmt --check", "lint": "oxlint --type-aware",
          "typecheck": "tsc --noEmit", "test:unit": "vitest run"}
base = "npm run format:check && npm run lint && npm run typecheck && npm run test:unit && npm run validate:repo --if-present"
want = {"node": base, "nextjs": base + " && npm run build", "vite": base + " && npm run build"}
problems, fast = [], set()
for p, validate in want.items():
    s = json.load(open(f"{d}/package-scripts.{p}.json"))
    fast.add(s.get("validate:fast"))
    if s.get("validate:fast") == old:
        problems.append(f"{p}: validate:fast is still the pre-change script")
    if set(s) != set(common) | {"validate", "validate:fast"}:
        problems.append(f"{p}: keys are {sorted(s)}")
    for k, v in {**common, "validate": validate}.items():
        if s.get(k) != v:
            problems.append(f"{p}: {k} = {s.get(k)!r}, want {v!r}")
if len(fast) != 1:
    problems.append(f"validate:fast differs across profiles: {sorted(map(repr, fast))}")
print("; ".join(problems))
sys.exit(1 if problems else 0)
EOF
)"; then
  ok "three profiles agree on validate:fast and other scripts are untouched"
else
  bad "three profiles agree on validate:fast and other scripts are untouched" "$msg"
fi

# --- drift gate: a fresh stamp is clean, the pre-change validate:fast is drift ---
fresh() { # stamped nextjs fixture repo, as bin/check-drift.test.sh builds it; any failed step → rc 1, no path
  local r; r="$(mktemp -d "$T/st.XXXXXX")" || return 1
  (cd "$r" && git init -q && git config core.hooksPath /dev/null \
    && printf '{"name":"fix","dependencies":{"next":"^16.3.1"},"scripts":{"build":"true"}}' > package.json \
    && printf '{"lockfileVersion":3,"packages":{"node_modules/next":{"version":"16.3.1"}}}' > package-lock.json \
    && printf 'import { it } from "vitest";\nit("smoke", () => {});\n' > smoke.test.ts \
    && printf '{}' > tsconfig.json && git add -A && git -c user.name=ci -c user.email=ci@example.com commit -q -m init) || return 1
  bash "$KITROOT/bin/stamp.sh" "$r" --profile nextjs >/dev/null || return 1
  echo "$r"
}
drift() { set +e; out=$(KIT_DIR="$KITROOT" bash "$KITROOT/bin/check-drift.sh" "$1" 2>&1); rc=$?; set -e; }

R=$(fresh) || { echo "FAIL stamped fixture repo was not built"; exit 1; }
drift "$R"
[ "$rc" = 0 ] && ok "freshly stamped repo passes the drift gate" \
  || bad "freshly stamped repo passes the drift gate" "rc=$rc out=$out"

R=$(fresh) || { echo "FAIL stamped fixture repo was not built"; exit 1; }
python3 -c "
import json, sys; p = sys.argv[1] + '/package.json'; d = json.load(open(p))
d['scripts']['validate:fast'] = sys.argv[2]; json.dump(d, open(p, 'w'))" "$R" "$OLD"
drift "$R"
[ "$rc" != 0 ] && has 'DRIFT' && has 'scripts.validate:fast' \
  && ok "pre-change validate:fast is reported as drift" \
  || bad "pre-change validate:fast is reported as drift" "rc=$rc out=$out"

# --- stop hook: a clean stamped npm repo releases the stop without running validate:fast ---
R="$(mktemp -d "$T/sv.XXXXXX")"
(cd "$R" && git init -q && git config core.hooksPath /dev/null && printf '{"runner": "npm"}' > .quality-kit.json \
  && git add -A && git -c user.name=t -c user.email=t@t commit -q -m init) \
  || { echo "FAIL stop-hook fixture repo was not built"; exit 1; }
: > "$NPM_LOG"
set +e; (cd "$R" && echo '{}' | bash "$KITROOT/hooks/stop-validate.sh" >/dev/null 2>&1); rc=$?; set -e
[ "$rc" = 0 ] && [ ! -s "$NPM_LOG" ] \
  && ok "clean stamped repo releases the stop without running npm" \
  || bad "clean stamped repo releases the stop without running npm" "rc=$rc npm=$(cat "$NPM_LOG")"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
