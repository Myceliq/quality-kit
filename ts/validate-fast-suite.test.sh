#!/usr/bin/env bash
# What: runs ts/validate-fast.test.sh itself, three times — once with no JS toolchain on PATH,
#       and once from each of two copies of the kit whose canonical JSONs carry an earlier
#       validate:fast. Where: quality-kit/ts.
# Why:  that suite's promises are about the suite, not the script (#45): it must stay green
#       (never SKIP) on a box with no node/npm/vitest, and it must go red against the old
#       `vitest run --changed` line and against 0.5.6's `git status` guard, which refused a clean
#       tree before vitest could collect anything (#80). None is visible from inside it — the selftest gate runs it
#       with the caller's PATH, which has the node that installed ci/oxlint-toolchain, and against
#       the current JSONs. Separate file, not a case in that suite, so nothing re-enters itself.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
KITROOT="$(cd "$DIR/.." && pwd)"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }

OLD='npm run format:check && npm run lint && npm run typecheck && vitest run --changed'
# 0.5.6's script, verbatim: the clean-tree decision is taken from `git status`, ahead of vitest.
GUARD='npm run format:check && npm run lint && npm run typecheck && changed=$(git status --porcelain --untracked-files=all) && { if [ -z "$changed" ]; then echo '"'"'validate:fast: no tests collected - the working tree is clean, so vitest run --changed selects nothing. Run npm run validate for the full suite, or vitest run --changed <ref> for the commits since <ref>.'"'"' >&2; exit 1; fi; vitest run --changed; }'

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# --- no JS toolchain: every executable on PATH except node, npm, npx, corepack and vitest ---
# Symlinked in PATH order, first name wins, so each surviving command resolves as it did before.
mkdir -p "$T/nojs"
IFS=: read -r -a path_dirs <<<"$PATH"
for d in "${path_dirs[@]}"; do
  [ -n "$d" ] && [ -d "$d" ] || continue
  for f in "$d"/*; do
    n="${f##*/}"
    case "$n" in node|npm|npx|corepack|vitest) continue ;; esac
    [ -f "$f" ] && [ -x "$f" ] && [ ! -e "$T/nojs/$n" ] && [ ! -L "$T/nojs/$n" ] || continue
    ln -s "$f" "$T/nojs/$n"
  done
done

leaked=""
for n in node npm npx corepack vitest; do
  env PATH="$T/nojs" bash -c "command -v $n" >/dev/null 2>&1 && leaked="$leaked $n"
done
if [ -n "$leaked" ]; then
  bad "validate-fast suite runs without a JS toolchain" "still resolvable on the stripped PATH:$leaked"
else
  set +e; out=$(env PATH="$T/nojs" bash "$DIR/validate-fast.test.sh" 2>&1); rc=$?; set -e
  [ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | tail -n 1)" = 'ALL PASS' ] \
    && ! printf '%s\n' "$out" | grep -q '^SKIP' \
    && ok "validate-fast suite runs without a JS toolchain" \
    || bad "validate-fast suite runs without a JS toolchain" "rc=$rc out=$out"
fi

# --- earlier scripts: a kit copy with one in all three profiles goes red, on the case it broke ---
# The copy keeps bin/, hooks/, ts/, agents/ and VERSION: the suite runs stamp.sh, check-drift.sh
# and stop-validate.sh relative to its own location.
red_against() { # $1=name $2=script $3=the FAIL line that script must produce
  local kit; kit="$(mktemp -d "$T/kit.XXXXXX")/kit"
  if python3 - "$KITROOT" "$kit" "$2" <<'EOF'
import json, shutil, sys
src, dst, old = sys.argv[1:]
shutil.copytree(src, dst, symlinks=True, ignore=shutil.ignore_patterns(".git", "node_modules"))
for p in ("node", "nextjs", "vite"):
    f = f"{dst}/ts/package-scripts.{p}.json"
    s = json.load(open(f))
    s["validate:fast"] = old
    with open(f, "w") as h:
        json.dump(s, h, indent=2)
        h.write("\n")
EOF
  then
    set +e; out=$(bash "$kit/ts/validate-fast.test.sh" 2>&1); rc=$?; set -e
    # The named FAIL, not just any: a broken copy (no stamp.sh, say) also fails, but not there.
    [ "$rc" != 0 ] && printf '%s\n' "$out" | grep -q "^FAIL .*$3" \
      && ok "validate-fast suite goes red against $1" \
      || bad "validate-fast suite goes red against $1" "rc=$rc out=$out"
  else
    bad "validate-fast suite goes red against $1" "kit copy was not built"
  fi
}
red_against "the pre-change script" "$OLD" 'clean tree fails loudly'
red_against "the 0.5.6 git-status guard" "$GUARD" 'runs the tests a base-ref config selects'

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
