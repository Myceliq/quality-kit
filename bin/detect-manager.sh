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
#       A declaration naming a manager the kit does not serve is a signal too,
#       emitted as `unsupported:<sanitised name>` so the callers refuse it by
#       name and no sanitised value can ever come out looking supported.
#       Silence there would be indistinguishable from no evidence, i.e. npm.
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
    d = json.load(open('package.json'))
except Exception:
    sys.exit(0)
if not isinstance(d, dict) or 'packageManager' not in d:
    sys.exit(0)   # no declaration is no evidence, which is not an error
pm = d['packageManager']
name = pm.split('@')[0].strip() if isinstance(pm, str) else ''
if name in ('npm', 'pnpm', 'yarn', 'bun'):
    print(name)
else:
    # A declaration naming something else is positive evidence of a manager the
    # kit does not serve, and it MUST become a signal. Printing nothing is what
    # made a deno repo indistinguishable from a bare one: both callers read the
    # empty output as 'no evidence' and default to npm, so the repo got a GREEN
    # stamp carrying npm-ci CI — the exact silent-npm outcome #7's scope note
    # forbids. As a signal it lands in the same '*)' arm as yarn and bun and is
    # refused BY NAME.
    # The 'unsupported:' prefix is load bearing, not decoration: the name is
    # sanitised to [A-Za-z0-9._-] so the token can never carry a space (which
    # would split the space-separated signal list) or a shell metacharacter, and
    # sanitising ALONE can promote a rejected name into a supported one —
    # 'pnpm!@9.0.0' sanitises to a bare 'pnpm', which would stamp the pnpm
    # workflow for a declaration corepack cannot resolve (codex, round 2). The
    # prefix makes that structurally impossible, since no supported value
    # contains a colon. The match above is case-SENSITIVE, so 'Deno@2' and even
    # 'PNPM@9' come through here rather than resolving — as corepack treats them.
    # A value with no usable name at all ('', '@1.2.3', a non-string, null)
    # still has to refuse rather than default, so it gets a placeholder name.
    print('unsupported:' + (re.sub(r'[^A-Za-z0-9._-]', '', name)[:24] or 'unnamed'))
"
  fi
  true
)"
# xargs rather than grep -v + tr: `pipefail` is on, and a grep that matches nothing
# exits 1, which under `set -e` aborts on exactly the common case — a repo with no
# signals at all. xargs collapses the blanks and cannot fail on empty input.
printf '%s\n' "$DETECTED" | sort -u | xargs
