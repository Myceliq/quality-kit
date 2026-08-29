#!/usr/bin/env bash
# What: report which JS package manager a repo uses, as a sorted signal list.
# Where: quality-kit/bin; called by stamp.sh before it writes and by
#        check-drift.sh before it verifies.
# Why:  the stamper and the gate MUST agree about the manager. One decides which
#       quality.yml to write; the other decides which quality.yml to compare
#       against and which lockfile the `next` floor is read from. Two copies of
#       this rule would drift, and the drift is invisible: a repo stamped for
#       pnpm whose gate keeps looking for package-lock.json stays permanently
#       red on a file it will never have — the #7 failure, moved not fixed.
#
#       Prints EVERY signal it finds, sorted, space-separated, and exits 0.
#       Resolving a multi-signal answer is the caller's job on purpose: "npm
#       pnpm" is ambiguous, both callers refuse it with their own remedy text,
#       and a detector that picked one would hide the ambiguity behind a guess.
#       Empty output means no signal at all, which is NOT an error — stamping
#       before the first install reconcile is a normal flow.
#
#       The LOCKFILE is the signal that matters, because it is what CI installs
#       and it is the ground truth everywhere else in this kit. A declared
#       `packageManager` is read as well, and only ever ADDS a signal: it is the
#       one piece of evidence a repo has before its first lockfile is committed,
#       and it can never override a lockfile — a disagreement between them comes
#       back as two signals, i.e. ambiguous, i.e. refused by both callers.
set -euo pipefail
REPO="${1:?usage: detect-manager.sh <repo>}"
cd "$REPO"

DETECTED="$(
  [ -f package-lock.json ] && echo npm
  [ -f pnpm-lock.yaml ]    && echo pnpm
  [ -f yarn.lock ]         && echo yarn
  { [ -f bun.lockb ] || [ -f bun.lock ]; } && echo bun
  if [ -f package.json ]; then
    python3 -c "
import json, re, sys
try:
    pm = json.load(open('package.json')).get('packageManager')
except Exception:
    sys.exit(0)
if isinstance(pm, str):
    m = re.match(r'([a-z]+)', pm.strip())
    if m and m.group(1) in ('npm', 'pnpm', 'yarn', 'bun'):
        print(m.group(1))
"
  fi
  true
)"
# xargs rather than grep -v + tr: `pipefail` is on, and a grep that matches nothing
# exits 1, which under `set -e` aborts on exactly the common case — a repo with no
# signals at all. xargs collapses the blanks and cannot fail on empty input.
printf '%s\n' "$DETECTED" | sort -u | xargs
