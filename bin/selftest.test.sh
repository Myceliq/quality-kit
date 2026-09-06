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

[ "$fail" -eq 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
