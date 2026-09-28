#!/usr/bin/env bash
# What: discover and run every *.test.sh suite in the repo.
# Why:  quality-kit gates the fleet; its own tests must be discovered, not
#       hand-enumerated, so new suites are automatically included and an empty
#       glob fails closed instead of silently passing.
set -euo pipefail

# `CDPATH=` on the cd itself: with CDPATH exported and a RELATIVE argument, bash's
# `cd` PRINTS the directory it resolved to, and the command substitution swallows
# that line too — ROOT comes out as the path twice over and the `cd "$ROOT"` below
# then fails on a path that does not exist. Measured: with CDPATH set,
# `ROOT="$(cd bin/.. && pwd)"` yields "<path>\n<path>". A stamped repo's CI invokes
# this as `bash .quality-kit-src/bin/selftest.sh` — relative — so the trigger is one
# exported variable away in an environment the kit does not own.
# `validate` is the kit's single self-gate command: it requires the pinned oxlint
# toolchain and refuses loudly (non-zero, naming the missing toolchain) when it
# is absent, instead of running the integration suites as silent skips. The four
# suites below — ts/oxlint-clean, ts/oxfmt-clean, ts/oxlint-overrides,
# ts/kit-checkout-ignored — each exit 0 printing SKIP when OXLINT_BIN/OXFMT_BIN
# are unset, so without this guard a missing toolchain reads as a green run.
# KIT_SELFTEST_NO_TOOLCHAIN=1 opts OUT explicitly (the stamped consumer `Kit
# self-test` step sets it: that step runs before install on purpose and can never
# have a toolchain). Opt-out is a NAMED var, never mere absence — absence-is-skip
# is the hole this guard closes (#40), and the opt-out keeps working when set to
# any non-empty value so callers need not agree on a spelling.
if [ -z "${KIT_SELFTEST_NO_TOOLCHAIN:-}" ]; then
  missing=()
  [ -n "${OXLINT_BIN:-}" ] || missing+=("OXLINT_BIN")
  [ -n "${OXFMT_BIN:-}" ] || missing+=("OXFMT_BIN")
  if [ "${#missing[@]}" -gt 0 ]; then
    echo "selftest: refusing — missing required toolchain: ${missing[*]} (install it exactly as .github/workflows/tests.yml does: npm ci in ci/oxlint-toolchain, then export OXLINT_BIN/OXFMT_BIN)" >&2
    exit 1
  fi
fi

ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# `bin/selftest.test.sh` is deliberately NOT excluded. Excluding it looks like recursion avoidance
# and is not: that suite copies this runner into throwaway roots and runs it THERE, against its own
# fixtures, so nothing re-enters this tree. What the exclusion actually bought was a runner whose
# own tests CI never ran — free to regress unnoticed, in the one file that decides whether every
# other suite gets executed at all.
#
# find writes to a FILE and its status is checked, rather than being piped straight into the read
# loop. In `done < <(find …)` the exit status belongs to the process substitution and is discarded,
# so an unreadable directory or an I/O error mid-traversal would yield a SHORT list that then ran
# and passed — the silent partial run, which is the same failure as the empty glob this guards
# against, only harder to notice because something did execute.
found="$(mktemp)"
trap 'rm -f "$found"' EXIT
find . -name '*.test.sh' \
  -not -path './.git/*' \
  -not -path '*/node_modules/*' \
  -print0 >"$found" || {
    echo "selftest: discovery failed — the suite list is incomplete, refusing to report on it" >&2
    exit 1
  }

suites=()
while IFS= read -r -d '' suite; do
  suites+=("$suite")
done < <(sort -z <"$found")

if [ "${#suites[@]}" -eq 0 ]; then
  echo "selftest: no *.test.sh suites discovered" >&2
  exit 1
fi

# COUNTED, not flagged. `fail=1` made the summary say "1 failed" whether one suite failed or nine
# — and that line is the one a reader scans to size the damage before opening the log.
failed=0
for suite in "${suites[@]}"; do
  rel="${suite#./}"
  echo "=== $rel ==="
  bash "$suite" || failed=$((failed + 1))
done

echo "selftest: ${#suites[@]} suite(s) ran, $failed failed"
# The exit status is a boolean, so the count is clamped rather than returned: `exit 256` wraps to
# 0 and would report a catastrophic run as success.
[ "$failed" -eq 0 ] || exit 1
