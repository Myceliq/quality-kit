#!/usr/bin/env bash
# What:  report, per repo, whether the effective pre-commit hook IS the global gate.
# Where: run by hand over a workspace root; `hooks-doctor.sh ~/workspace`.
# Why:   the gate's failure mode is silence. A repo-local core.hooksPath overrides
#        the global one with no warning, and git skips a hooks dir that has no
#        pre-commit without any error at all — so a repo can go months committing
#        unreviewed and look identical to one that is gated. Nothing else on the
#        box answers "is the gate actually live here?".
#
# Exit 0 when every repo is gated by the current global hook, 1 otherwise.
set -uo pipefail

# git expands a leading ~ in core.hooksPath. Left literal, a "~/..." value is
# neither absolute nor a real directory, so the global gate reads as missing and
# every repo's path resolves to <repo>/~/... — the whole fleet reported ungated
# while it was fine. Both readers of the setting go through here.
expand_tilde() {
  case "$1" in
    "~/"*) printf '%s\n' "$HOME/${1#\~/}" ;;
    *)     printf '%s\n' "$1" ;;
  esac
}

# The global gate lives wherever core.hooksPath says — ASK git, don't assume.
# Hard-coding ~/.config/git/hooks made this report every repo GATE-OFF on a box
# whose gate was live at ~/bin/githooks: a checker that cries wolf on a healthy
# fleet is one nobody runs, which is the same silence it exists to break.
GLOBAL_HOOKS_DIR="${GIT_GLOBAL_HOOKS:-$(git config --global --get core.hooksPath 2>/dev/null || true)}"
GLOBAL_HOOKS_DIR="$(expand_tilde "${GLOBAL_HOOKS_DIR:-$HOME/.config/git/hooks}")"
GLOBAL_HOOK="$GLOBAL_HOOKS_DIR/pre-commit"
ROOT="${1:-$HOME/workspace}"
MAXDEPTH="${HOOKS_DOCTOR_MAXDEPTH:-5}"

# A RELATIVE global core.hooksPath is legal, and it breaks this script's whole
# model: git resolves it from each worktree root, so every repo has its OWN copy
# and there is no single file for "differs from the global gate" to mean anything
# against. Resolved against this script's cwd instead, the preflight below exits
# before scanning a single repo — reporting a healthy fleet as having no gate at
# all. Refuse loudly rather than answer confidently while unable to tell.
case "$GLOBAL_HOOKS_DIR" in
  /*) ;;
  *)
    echo "hooks-doctor: global core.hooksPath is relative ($GLOBAL_HOOKS_DIR)." >&2
    echo "hooks-doctor: git resolves that per worktree, so there is no single global" >&2
    echo "hooks-doctor: gate to compare against. Set an absolute path, or point" >&2
    echo "hooks-doctor: GIT_GLOBAL_HOOKS at the canonical hooks directory." >&2
    exit 1
    ;;
esac

if [ ! -x "$GLOBAL_HOOK" ]; then
  echo "hooks-doctor: no executable global hook at $GLOBAL_HOOK" >&2
  exit 1
fi

# A missing/unreadable ROOT makes `find` fail silently (stderr discarded below);
# the loop then never runs, bad stays 0, and the script would print false success.
if [ ! -d "$ROOT" ] || [ ! -r "$ROOT" ]; then
  echo "hooks-doctor: root not found or unreadable: $ROOT" >&2
  exit 1
fi

bad=0
# `find` FAILING must never read as "nothing wrong". An invalid
# HOOKS_DOCTOR_MAXDEPTH, or a traversal error, yields an empty or short list;
# the loop then never runs, bad stays 0, and this printed "all repos gated"
# and exited 0 — a whole unscanned fleet certified healthy, which is the exact
# false success this script exists to prevent. Measured before the fix:
# HOOKS_DOCTOR_MAXDEPTH=abc → "all repos gated", exit 0.
# Collected to a file rather than a process substitution so the pipeline's
# status is observable at all; `pipefail` (set at the top) makes that status
# find's, not sort's. A partial traversal still prints what it found — the
# rows are useful — but can never end in a clean bill.
FOUND="$(mktemp)"
trap 'rm -f "$FOUND"' EXIT
discovery_failed=0
if ! find "$ROOT" -maxdepth "$MAXDEPTH" -name .git 2>/dev/null | sort > "$FOUND"; then
  echo "hooks-doctor: repo discovery failed under $ROOT (maxdepth=$MAXDEPTH)." >&2
  echo "hooks-doctor: any results below are INCOMPLETE — not a clean bill of health." >&2
  discovery_failed=1
fi

# -name .git matches worktrees too, where it is a FILE rather than a directory.
while IFS= read -r dotgit; do
  repo="$(dirname "$dotgit")"

  # An orphaned worktree — a .git FILE pointing at a gitdir that no longer exists,
  # left behind by `worktree prune`. git refuses every command there, so no commit
  # can happen and there is no gate to be missing: reporting it as ungated is a
  # false positive, and a checker that cries wolf is one nobody runs.
  # --path-format=absolute: bare --git-common-dir prints ".git" (relative to
  # git's OWN cwd, not the caller's), so hooks_dir below would resolve against
  # wherever this script was invoked from instead of $repo.
  if ! common_dir="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || [ -z "$common_dir" ]; then
    printf 'ORPHAN   %-46s %s\n' "$repo" "stale worktree, git unusable — not a gate failure"
    continue
  fi

  # Effective value: a bare --get already applies local-over-global precedence,
  # which is exactly the shadowing that hides a dead gate.
  hp="$(git -C "$repo" config --get core.hooksPath 2>/dev/null || true)"
  hp="$(expand_tilde "$hp")"
  if [ -z "$hp" ]; then
    hooks_dir="$common_dir/hooks"
  else
    case "$hp" in /*) hooks_dir="$hp" ;; *) hooks_dir="$repo/$hp" ;; esac
  fi

  scope="$(git -C "$repo" config --local --get core.hooksPath >/dev/null 2>&1 && echo "local" || echo "global")"

  if [ ! -x "$hooks_dir/pre-commit" ]; then
    printf 'GATE-OFF %-46s %s\n' "$repo" "$hooks_dir (no executable pre-commit)"
    bad=1
  elif cmp -s "$hooks_dir/pre-commit" "$GLOBAL_HOOK"; then
    printf 'OK       %-46s %s\n' "$repo" "$scope"
  else
    # Runs SOMETHING, but not the current gate — typically a forked copy that
    # predates later fixes, so it silently lacks whatever was added since.
    printf 'STALE    %-46s %s\n' "$repo" "$hooks_dir (differs from global gate)"
    bad=1
  fi
done < "$FOUND"

# The clean bill requires BOTH that every repo scanned was gated AND that the
# scan actually covered the tree. Either one alone is a claim this script cannot
# support.
if [ "$bad" = 0 ] && [ "$discovery_failed" = 0 ]; then
  echo "hooks-doctor: all repos gated by the current global hook"
  exit 0
fi
exit 1
