#!/usr/bin/env bash
# What: tests for selftest.sh. Where: quality-kit/bin.
# Why:  the self-test runner gates the kit's own suites; a missed exclusion,
#       silent empty glob, or recursion into its own suite would let broken
#       code through.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
SELFTEST="$DIR/selftest.sh"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }

mkroot() {
  local root="$1"
  mkdir -p "$root/bin"
  cp "$SELFTEST" "$root/bin/selftest.sh"
  chmod +x "$root/bin/selftest.sh"
}

tmpbase="$(mktemp -d)"
cleanup() { rm -rf "$tmpbase"; }
trap cleanup EXIT

# The runner under test now refuses when the toolchain vars are unset, so every
# fixture run below sets dummies. The fixtures are trivial scripts that never
# read them — the vars only get the copied runner past its guard, the same way
# CI's real values get the real runner past it. The missing-toolchain cases
# strip them again with `env -u`.
export OXLINT_BIN=/nonexistent/oxlint OXFMT_BIN=/nonexistent/oxfmt
# The guard's opt-out must never leak INTO a fixture from this suite's own
# environment: under `KIT_SELFTEST_NO_TOOLCHAIN=1 make validate` (the stamped
# consumer shape) the refusal cases below would inherit the opt-out and pass
# vacuously. Stripped per-case beside the toolchain vars, never exported here.

# --- one passing suite ---
root="$tmpbase/pass"
mkroot "$root"
printf '%s\n' 'echo pass-ok' > "$root/pass.test.sh"
chmod +x "$root/pass.test.sh"
rc=0; out="$(cd "$root" && bash bin/selftest.sh 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] \
   && grep -q '^=== pass.test.sh ===$' <<<"$out" \
   && grep -q 'selftest: 1 suite(s) ran, 0 failed' <<<"$out"; then
  ok "single passing suite"
else
  bad "single passing suite" "rc=$rc out=$out"
fi

# --- failing suite makes runner fail closed ---
root="$tmpbase/fail"
mkroot "$root"
printf '%s\n' 'echo fail-ok; exit 1' > "$root/fail.test.sh"
chmod +x "$root/fail.test.sh"
rc=0; out="$(cd "$root" && bash bin/selftest.sh 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] \
   && grep -q '^=== fail.test.sh ===$' <<<"$out" \
   && grep -q 'selftest: 1 suite(s) ran, 1 failed' <<<"$out"; then
  ok "failing suite fails closed"
else
  bad "failing suite fails closed" "rc=$rc out=$out"
fi

# --- the summary COUNTS failures, it does not flag them ---
# A `fail=1` accumulator reports "1 failed" whether one suite failed or nine, and that line is what
# a reader scans to size the damage before opening the log. Three failures must say three.
root="$tmpbase/multifail"
mkroot "$root"
for n in 1 2 3; do
  printf '%s\n' "echo bad-$n; exit 1" > "$root/bad$n.test.sh"
  chmod +x "$root/bad$n.test.sh"
done
printf '%s\n' 'echo good; exit 0' > "$root/good.test.sh"
chmod +x "$root/good.test.sh"
rc=0; out="$(cd "$root" && bash bin/selftest.sh 2>&1)" || rc=$?
if [ "$rc" -eq 1 ] && grep -q 'selftest: 4 suite(s) ran, 3 failed' <<<"$out"; then
  ok "the summary counts every failure, and the exit stays 1"
else
  bad "the summary counts every failure" "rc=$rc out=$out"
fi

# --- a suite named selftest.test.sh is discovered like any other ---
# It used to be excluded by name, which looked like recursion avoidance and was not: this file
# only ever runs COPIES of the runner in throwaway roots. The exclusion bought a runner whose own
# tests CI never ran — in the one file that decides whether every other suite executes at all.
#
# Asserted in a temp root, deliberately. Invoking the REAL runner from here would recurse for
# real: it would discover this file, run it, and this case would invoke the runner again.
root="$tmpbase/ownsuite"
mkroot "$root"
printf '%s\n' 'echo own-ok; exit 0' > "$root/bin/selftest.test.sh"
chmod +x "$root/bin/selftest.test.sh"
rc=0; out="$(cd "$root" && bash bin/selftest.sh 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && grep -q '^=== bin/selftest.test.sh ===$' <<<"$out"; then
  ok "a suite named selftest.test.sh is discovered, not skipped by name"
else
  bad "a suite named selftest.test.sh is discovered" "rc=$rc out=$out"
fi

# --- excluded paths are skipped ---
root="$tmpbase/excluded"
mkroot "$root"
printf '%s\n' 'echo good' > "$root/good.test.sh"
mkdir -p "$root/.git" "$root/node_modules"
printf '%s\n' 'exit 1' > "$root/.git/bad.test.sh"
printf '%s\n' 'exit 1' > "$root/node_modules/bad.test.sh"
chmod +x "$root/good.test.sh" "$root/.git/bad.test.sh" "$root/node_modules/bad.test.sh"
rc=0; out="$(cd "$root" && bash bin/selftest.sh 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] \
   && grep -q '^=== good.test.sh ===$' <<<"$out" \
   && grep -q 'selftest: 1 suite(s) ran, 0 failed' <<<"$out" \
   && ! grep -q 'bad.test.sh' <<<"$out"; then
  ok "excluded paths are skipped"
else
  bad "excluded paths are skipped" "rc=$rc out=$out"
fi

# --- zero suites discovered is a failure ---
root="$tmpbase/empty"
mkroot "$root"
rc=0; out="$(cd "$root" && bash bin/selftest.sh 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] && grep -q 'no \*\.test\.sh suites discovered' <<<"$out"; then
  ok "zero suites discovered fails closed"
else
  bad "zero suites discovered fails closed" "rc=$rc out=$out"
fi

# --- a missing toolchain refuses loudly instead of passing as skips ---
# The config-integration suites exit 0 printing SKIP when OXLINT_BIN/OXFMT_BIN
# are unset, so without the guard a missing toolchain reads as a green run.
# (TDD: this case failed before the guard existed — the copied runner exited 0.)
root="$tmpbase/notoolchain"
mkroot "$root"
printf '%s\n' 'echo skip-ok' > "$root/skip.test.sh"
chmod +x "$root/skip.test.sh"
rc=0; out="$(cd "$root" && env -u OXLINT_BIN -u OXFMT_BIN -u KIT_SELFTEST_NO_TOOLCHAIN bash bin/selftest.sh 2>&1)" || rc=$?
line="$(grep 'missing required toolchain' <<<"$out" || true)"
if [ "$rc" -ne 0 ] && grep -q 'OXLINT_BIN' <<<"$line" && grep -q 'OXFMT_BIN' <<<"$line"; then
  ok "missing toolchain refuses loudly, naming the toolchain"
else
  bad "missing toolchain refuses loudly" "rc=$rc out=$out"
fi

# --- the refusal names exactly the missing var ---
# Matched on the `toolchain:` prefix, not the bare var name: the install hint
# later in the same line names both vars either way.
root="$tmpbase/halftoolchain"
mkroot "$root"
printf '%s\n' 'echo skip-ok' > "$root/skip.test.sh"
chmod +x "$root/skip.test.sh"
rc=0; out="$(cd "$root" && env -u OXFMT_BIN -u KIT_SELFTEST_NO_TOOLCHAIN bash bin/selftest.sh 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] && grep -qF 'toolchain: OXFMT_BIN (' <<<"$out"; then
  ok "the refusal names exactly the missing var"
else
  bad "the refusal names exactly the missing var" "rc=$rc out=$out"
fi

# --- the explicit opt-out keeps skip semantics for the stamped pre-install step ---
# The stamped consumer `Kit self-test` step sets KIT_SELFTEST_NO_TOOLCHAIN=1: it runs
# before install and can never have a toolchain. Opt-out is a NAMED var, never mere
# absence — the case above (absence refuses) and this one (named opt-out skips) are
# the paired arms, differing only in the env payload.
root="$tmpbase/optout"
mkroot "$root"
printf '%s\n' 'echo skip-ok' > "$root/skip.test.sh"
chmod +x "$root/skip.test.sh"
rc=0; out="$(cd "$root" && env -u OXLINT_BIN -u OXFMT_BIN KIT_SELFTEST_NO_TOOLCHAIN=1 bash bin/selftest.sh 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && grep -q '1 suite(s) ran, 0 failed' <<<"$out"; then
  ok "explicit opt-out keeps skip semantics without a toolchain"
else
  bad "explicit opt-out keeps skip semantics without a toolchain" "rc=$rc out=$out"
fi

# --- an empty opt-out is NOT an opt-out ---
# KIT_SELFTEST_NO_TOOLCHAIN="" must refuse exactly like unset: otherwise an exported-but-empty
# var in some CI environment silently re-opens the #40 hole.
root="$tmpbase/emptyoptout"
mkroot "$root"
printf '%s\n' 'echo skip-ok' > "$root/skip.test.sh"
chmod +x "$root/skip.test.sh"
rc=0; out="$(cd "$root" && env -u OXLINT_BIN -u OXFMT_BIN KIT_SELFTEST_NO_TOOLCHAIN="" bash bin/selftest.sh 2>&1)" || rc=$?
if [ "$rc" -ne 0 ] && grep -q 'missing required toolchain' <<<"$out"; then
  ok "empty opt-out still refuses"
else
  bad "empty opt-out still refuses" "rc=$rc out=$out"
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
