#!/usr/bin/env bash
# What: tests for the repo-root Makefile's toolchain resolution. Where: quality-kit/bin.
# Why:  #55 — a factory run's commit path (hook → make validate-fast) never exports
#       OXLINT_BIN/OXFMT_BIN, and run 1 failed implement-no-commit with every commit
#       rejected at the hook for exactly that. The Makefile must install the pinned
#       toolchain itself when the vars are unset, and must NOT install when a caller
#       already exported them.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }

tmpbase="$(mktemp -d)"
cleanup() { rm -rf "$tmpbase"; }
trap cleanup EXIT

# The fixture is a THROWAWAY repo root carrying a COPY of the real Makefile plus a
# fake toolchain dir — never the real ci/oxlint-toolchain, whose `npm ci` takes
# minutes and needs network. The Makefile's decision points are (a) are the vars
# set, (b) are the bins executable; both are observable without a real install by
# pointing the copy at a stub `npm` that records it ran. `make` itself is the real
# binary: a stubbed make would prove nothing about the recipe's shell.
mkfixture() {
  local root="$1"
  mkdir -p "$root/ci/oxlint-toolchain" "$root/bin" "$root/stubbin"
  cp "$ROOT/Makefile" "$root/Makefile"
  cp "$ROOT/bin/selftest.sh" "$root/bin/selftest.sh"
  chmod +x "$root/bin/selftest.sh"
  # Stub npm: records the invocation, then materialises executable bins so the
  # recipe's `-x` checks pass on the selftest.sh the copy invokes. No network.
  cat > "$root/stubbin/npm" <<'EOF'
#!/usr/bin/env bash
echo "stub-npm $*" >> "$STUB_LOG"
mkdir -p node_modules/.bin
printf '#!/usr/bin/env bash\nexit 0\n' > node_modules/.bin/oxlint
printf '#!/usr/bin/env bash\nexit 0\n' > node_modules/.bin/oxfmt
chmod +x node_modules/.bin/oxlint node_modules/.bin/oxfmt
EOF
  chmod +x "$root/stubbin/npm"
  printf '%s\n' 'echo fixture-ok' > "$root/fixture.test.sh"
  chmod +x "$root/fixture.test.sh"
}

# --- unset vars + missing bins: the Makefile installs, then gates green ---
root="$tmpbase/install"
mkfixture "$root"
export STUB_LOG="$root/stub.log" PATH="$root/stubbin:$PATH"
rc=0; out="$(cd "$root" && env -u OXLINT_BIN -u OXFMT_BIN -u KIT_SELFTEST_NO_TOOLCHAIN make validate 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && grep -q 'installing from the pinned lockfile' <<<"$out" \
   && [ -f "$root/stub.log" ] && grep -q '1 suite(s) ran, 0 failed' <<<"$out"; then
  ok "unset vars + missing bins installs the toolchain, then gates green"
else
  bad "unset vars + missing bins installs the toolchain" "rc=$rc out=$out"
fi

# --- pre-set vars: no install, vars pass through to the gate ---
# Paired arm: byte-identical fixture, only the env payload differs. The bins are
# materialised WITHOUT npm (no stub.log possible), so any install attempt fails
# loudly on a missing stub rather than silently passing.
root="$tmpbase/preset"
mkfixture "$root"
mkdir -p "$root/ci/oxlint-toolchain/node_modules/.bin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$root/ci/oxlint-toolchain/node_modules/.bin/oxlint"
printf '#!/usr/bin/env bash\nexit 0\n' > "$root/ci/oxlint-toolchain/node_modules/.bin/oxfmt"
chmod +x "$root/ci/oxlint-toolchain/node_modules/.bin/"*
rm "$root/stubbin/npm"  # any install attempt now fails: `npm: command not found`
rc=0; out="$(cd "$root" && OXLINT_BIN=/preset/oxlint OXFMT_BIN=/preset/oxfmt KIT_SELFTEST_NO_TOOLCHAIN=1 PATH="/usr/bin:/bin" make validate 2>&1)" || rc=$?
# KIT_SELFTEST_NO_TOOLCHAIN=1 stands in for a REAL toolchain behind the preset vars:
# the fixture's /preset/* bins do not exist, so without the opt-out the guard would
# refuse on absence — which is the guard's own tested behavior, not this recipe's.
# What THIS arm proves is narrower and exact: preset vars → no install attempted.
if [ "$rc" -eq 0 ] && ! grep -q 'installing from the pinned lockfile' <<<"$out" \
   && grep -q '1 suite(s) ran, 0 failed' <<<"$out"; then
  ok "pre-set vars skip the install and gate green"
else
  bad "pre-set vars skip the install" "rc=$rc out=$out"
fi

# --- partial preset: the set var survives, the missing one resolves locally ---
# CodeRabbit #56: when only one var is unset, the recipe must not overwrite the
# preset var with a local path. Proved through the copied selftest's guard: the
# preset var is real-named but dangling, so the ONLY way this run greens is the
# recipe installing (stub npm) and exporting OXFMT_BIN at the installed bin while
# OXLINT_BIN keeps its preset value — observed via the install line + green gate.
# (The dangling preset value itself is never executed by the trivial fixture.)
root="$tmpbase/partial"
mkfixture "$root"
export STUB_LOG="$root/stub.log" PATH="$root/stubbin:$PATH"
rc=0; out="$(cd "$root" && OXLINT_BIN=/preset/oxlint env -u OXFMT_BIN -u KIT_SELFTEST_NO_TOOLCHAIN make validate 2>&1)" || rc=$?
# NOTE: `VAR=x env -u OTHER cmd` — the -u flags must come after VAR=x assignments
# on the env command line, else env treats them as variable names to set.
if [ "$rc" -eq 0 ] && grep -q 'installing from the pinned lockfile' <<<"$out" \
   && grep -q '1 suite(s) ran, 0 failed' <<<"$out"; then
  ok "partial preset installs the missing half and gates green"
else
  bad "partial preset installs the missing half" "rc=$rc out=$out"
fi

# --- a failed install is terminal, not a silent fallthrough ---
# Panel #56 (bugs, medium): make recipes run without -e, so a bare `;` after
# `npm ci` would proceed to export paths at bins that were never installed. The
# stub npm here exits 1 WITHOUT materialising bins; the recipe must exit non-zero
# and must NOT reach the gate (no `suite(s) ran` line at all).
root="$tmpbase/failinstall"
mkfixture "$root"
cat > "$root/stubbin/npm" <<'EOF'
#!/usr/bin/env bash
echo "stub-npm $* (failing)" >> "$STUB_LOG"
exit 1
EOF
chmod +x "$root/stubbin/npm"
export STUB_LOG="$root/stub.log" PATH="$root/stubbin:$PATH"
rc=0; out="$(cd "$root" && env -u OXLINT_BIN -u OXFMT_BIN -u KIT_SELFTEST_NO_TOOLCHAIN make validate 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] && grep -q 'installing from the pinned lockfile' <<<"$out" \
   && ! grep -q 'suite(s) ran' <<<"$out"; then
  ok "failed install is terminal and never reaches the gate"
else
  bad "failed install is terminal" "rc=$rc out=$out"
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
