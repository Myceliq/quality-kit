#!/usr/bin/env bash
# Tests for hooks-doctor's repo classification.
#
# Hermetic: GIT_GLOBAL_HOOKS points at a fixture "global" hook, so these assert
# the classification logic rather than the state of this machine. No commits are
# made, so no real hook fires.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCTOR="$DIR/hooks-doctor.sh"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

mkdir -p "$T/globalhooks" "$T/fakehome"
printf '#!/bin/sh\necho gate\n' > "$T/globalhooks/pre-commit"
chmod +x "$T/globalhooks/pre-commit"

mk_repo() {  # <name> -> repo path, git-initialised, no hooksPath set
  local p="$T/repos/$1"
  mkdir -p "$p" && git init -q "$p"
  git -C "$p" config user.email t@t && git -C "$p" config user.name t
  echo "$p"
}

# RELATIVE core.hooksPath resolves against the WORKTREE ROOT, not the gitdir.
# Verified directly: a hook at <worktree>/myhooks/pre-commit fires, and the same
# hook under .git/myhooks/ does not. githooks(5) is explicit — git chdirs to the
# root of the working tree before running hooks in a non-bare repo, and a
# relative core.hooksPath is taken from where the hooks are run. "Fixing" this to
# resolve against the gitdir reports correctly-gated repos as GATE-OFF, which is
# how a checker gets ignored.
R="$(mk_repo relative)"
mkdir -p "$R/myhooks" && cp "$T/globalhooks/pre-commit" "$R/myhooks/pre-commit"
chmod +x "$R/myhooks/pre-commit"
git -C "$R" config core.hooksPath myhooks

# A hooks dir with nothing executable in it — git skips it silently.
E="$(mk_repo empty)"
mkdir -p "$E/emptyhooks"
git -C "$E" config core.hooksPath emptyhooks

# Runs SOMETHING, but not the current gate.
S="$(mk_repo stale)"
mkdir -p "$S/forked" && printf '#!/bin/sh\necho old\n' > "$S/forked/pre-commit"
chmod +x "$S/forked/pre-commit"
git -C "$S" config core.hooksPath forked

out="$(GIT_GLOBAL_HOOKS="$T/globalhooks" HOOKS_DOCTOR_MAXDEPTH=4 bash "$DOCTOR" "$T/repos" 2>&1)"
rc=$?

grep -qE "^OK .*/relative" <<<"$out" \
  && ok "relative hooksPath resolves against the worktree root" \
  || bad "relative hooksPath resolves against the worktree root" "$out"

grep -qE "^GATE-OFF .*/empty" <<<"$out" \
  && ok "hooks dir with no pre-commit is GATE-OFF" \
  || bad "hooks dir with no pre-commit is GATE-OFF" "$out"

grep -qE "^STALE .*/stale" <<<"$out" \
  && ok "a forked hook is STALE, not OK" \
  || bad "a forked hook is STALE, not OK" "$out"

[ "$rc" != 0 ] \
  && ok "exits non-zero when a live repo is ungated" \
  || bad "exits non-zero when a live repo is ungated" "rc=$rc"

# An orphaned worktree: a .git FILE pointing at a gitdir that no longer exists.
# git refuses every command there, so no commit can happen and no gate can be
# missing. It must not count as a failure, or the checker reports the impossible.
O="$T/orphanroot/orphan"
mkdir -p "$O"
echo "gitdir: $T/orphanroot/.git/worktrees/gone" > "$O/.git"
oout="$(GIT_GLOBAL_HOOKS="$T/globalhooks" HOOKS_DOCTOR_MAXDEPTH=4 bash "$DOCTOR" "$T/orphanroot" 2>&1)"
orc=$?
grep -qE "^ORPHAN " <<<"$oout" && [ "$orc" = 0 ] \
  && ok "orphaned worktree reports ORPHAN and does not fail the run" \
  || bad "orphaned worktree reports ORPHAN and does not fail the run" "rc=$orc $oout"

# core.hooksPath UNSET (the common case) — common_dir must resolve absolute,
# not relative to the caller's cwd, or a correctly-gated repo gets
# misclassified depending on wherever hooks-doctor.sh happens to be invoked
# from. Isolate HOME too: an unset local hooksPath still falls through to
# whatever global hooksPath the running machine has configured.
D="$(mk_repo default)"
mkdir -p "$D/.git/hooks"
cp "$T/globalhooks/pre-commit" "$D/.git/hooks/pre-commit"
chmod +x "$D/.git/hooks/pre-commit"
dout="$(cd "$T" && env -i \
  PATH="$PATH" \
  HOME="$T/fakehome" \
  GIT_CONFIG_NOSYSTEM=1 \
  GIT_GLOBAL_HOOKS="$T/globalhooks" \
  HOOKS_DOCTOR_MAXDEPTH=4 \
  bash "$DOCTOR" "$T/repos" 2>&1)"
grep -qE "^OK .*/default" <<<"$dout" \
  && ok "default (unset) hooksPath resolves against the repo, not the caller's cwd" \
  || bad "default (unset) hooksPath resolves against the repo, not the caller's cwd" "$dout"

# The gate's location is whatever core.hooksPath says. Hard-coding the documented
# default (~/.config/git/hooks) reported every repo GATE-OFF on the one box this
# runs on, whose gate is live at ~/bin/githooks — the checker declaring the whole
# fleet ungated while it was fine. GIT_GLOBAL_HOOKS unset here on purpose: that
# override is the test harness's, not the mechanism under test.
printf '[core]\n\thooksPath = %s\n' "$T/globalhooks" > "$T/fakehome/.gitconfig"
cout="$(cd "$T" && env -i \
  PATH="$PATH" \
  HOME="$T/fakehome" \
  GIT_CONFIG_NOSYSTEM=1 \
  HOOKS_DOCTOR_MAXDEPTH=4 \
  bash "$DOCTOR" "$T/repos" 2>&1)"
grep -qE "^OK .*/default" <<<"$cout" \
  && ok "reads the configured global core.hooksPath, not a hard-coded default" \
  || bad "reads the configured global core.hooksPath, not a hard-coded default" "$cout"

# git expands a leading ~ in core.hooksPath, so this must too — left literal, the
# -x test can never succeed and every repo reads as ungated.
mkdir -p "$T/fakehome/tildehooks"
cp "$T/globalhooks/pre-commit" "$T/fakehome/tildehooks/pre-commit"
chmod +x "$T/fakehome/tildehooks/pre-commit"
printf '[core]\n\thooksPath = ~/tildehooks\n' > "$T/fakehome/.gitconfig"
tout="$(cd "$T" && env -i \
  PATH="$PATH" \
  HOME="$T/fakehome" \
  GIT_CONFIG_NOSYSTEM=1 \
  HOOKS_DOCTOR_MAXDEPTH=4 \
  bash "$DOCTOR" "$T/repos" 2>&1)"
grep -qE "^OK .*/default" <<<"$tout" \
  && ok "a ~-prefixed core.hooksPath is expanded, as git expands it" \
  || bad "a ~-prefixed core.hooksPath is expanded, as git expands it" "$tout"
rm -f "$T/fakehome/.gitconfig"

# A RELATIVE global core.hooksPath must be refused, not resolved against the
# doctor's cwd. git resolves it per worktree root, so there is no single global
# gate file; comparing repos to <cwd>/<rel>/pre-commit exits before scanning
# anything and reports a healthy fleet as ungated. Must say why, not just die.
printf '[core]\n\thooksPath = relhooks\n' > "$T/fakehome/.gitconfig"
rout="$(cd "$T" && env -i \
  PATH="$PATH" \
  HOME="$T/fakehome" \
  GIT_CONFIG_NOSYSTEM=1 \
  HOOKS_DOCTOR_MAXDEPTH=4 \
  bash "$DOCTOR" "$T/repos" 2>&1)"
rrc=$?
[ "$rrc" != 0 ] && grep -qi "relative" <<<"$rout" && ! grep -q "^OK " <<<"$rout" \
  && ok "a relative global hooksPath is refused with a reason, not misresolved" \
  || bad "a relative global hooksPath is refused with a reason, not misresolved" "rc=$rrc $rout"
rm -f "$T/fakehome/.gitconfig"

# A missing ROOT must fail closed, not silently print "all gated" with rc=0 —
# `find` errors to /dev/null, so an unchecked ROOT hides the failure entirely.
mout="$(GIT_GLOBAL_HOOKS="$T/globalhooks" bash "$DOCTOR" "$T/does-not-exist" 2>&1)"
mrc=$?
[ "$mrc" != 0 ] && ! grep -q "all repos gated" <<<"$mout" \
  && ok "missing ROOT fails closed instead of reporting silent success" \
  || bad "missing ROOT fails closed instead of reporting silent success" "rc=$mrc $mout"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
