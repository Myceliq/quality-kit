#!/usr/bin/env bash
# What: diff-aware turn-end gate — an agent cannot end its turn with the
#       working tree failing validate:fast.
# Where: stamped as .quality/stop-validate.sh; run by the stamped Claude Stop hook and by the
#       user-level Codex Stop hook (hooks/codex-stop.sh).
# Why:  closes "agent declares done without checking". exit 2 + stderr is the
#       block protocol in both runtimes. stop_hook_active releases after one
#       blocked round to avoid livelock — pre-commit and CI still gate behind it.
set -uo pipefail
payload="$(cat 2>/dev/null || true)"

# Resolve the repo from the SESSION'S cwd, not the hook process's own.
#
# Both runtimes launch a Stop hook with cwd set to the PROJECT dir, which is not necessarily the
# tree the session edited: a session working in a linked worktree would otherwise have the
# project dir validated, and every dirty file there attributed to it. On a box where several sessions share one primary checkout, that makes a
# peer's in-flight work block a session that never opened those files, and the message it prints
# ("fix before ending the turn") tells that session to fix work it does not own. Reproduced:
# a clean session worktree, a project dir carrying an unrelated session's broken untracked file,
# and this gate exits 2.
#
# Falls back to the hook's own cwd whenever the payload carries no usable directory, so a runtime
# that omits the field, or names one that has since been removed, behaves exactly as before.
session_cwd="$(printf '%s' "$payload" | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('cwd','') or '')
except Exception: print('')" 2>/dev/null)"
root=""
if [ -n "$session_cwd" ] && [ -d "$session_cwd" ]; then
  root="$(git -C "$session_cwd" rev-parse --show-toplevel 2>/dev/null)" || root=""
fi
[ -n "$root" ] || root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$root" ] || exit 0

# ...but only this project's own trees. The session's cwd can be any directory, including a clone
# of some other repository; this hook belongs to the project it is stamped into and validates
# that project's primary checkout and linked worktrees, nothing else. A tree belongs to the
# project when it shares its git common dir with the directory this script is installed in. The
# anchor is the script's location and not the process cwd, because the runtime's config names
# this file by path while the cwd it launches hooks from is the runtime's choice. Both sides are
# resolved to a physical absolute path first: `--git-common-dir` prints `.git` for a primary
# checkout and an absolute path for a worktree, and either may sit behind a symlink.
# Any other tree, a submodule included (its common dir is its own), exits 0 untouched.
common_dir() { # $1=dir inside a work tree → physical absolute path of its git common dir
  local g; g="$(git -C "$1" rev-parse --git-common-dir 2>/dev/null)" || return 1
  [ -n "$g" ] || return 1
  (cd "$1" && cd "$g" && pwd -P) 2>/dev/null
}
own="$(common_dir "$(dirname "${BASH_SOURCE[0]}")")" || exit 0
theirs="$(common_dir "$root")" || exit 0
[ -n "$own" ] && [ "$own" = "$theirs" ] || exit 0

cd "$root" || exit 0
[ -f .quality-kit.json ] || exit 0

changed="$(git status --porcelain --untracked-files=all | cut -c4-)"
[ -z "$changed" ] && exit 0
# docs-only diffs skip validation
printf '%s\n' "$changed" | grep -qvE '(^docs/|\.md$|\.txt$)' || exit 0

runner="$(python3 -c "import json;print(json.load(open('.quality-kit.json')).get('runner','npm'))" 2>/dev/null)"
case "$runner" in
  npm)  cmd=(npm run --silent validate:fast) ;;
  make) cmd=(make validate-fast) ;;
  *)    exit 0 ;;
esac

out="$("${cmd[@]}" 2>&1)"; status=$?
[ "$status" -eq 0 ] && exit 0

active="$(printf '%s' "$payload" | python3 -c "import json,sys
try: print(json.load(sys.stdin).get('stop_hook_active',False))
except Exception: print(False)" 2>/dev/null)"
if [ "$active" = "True" ]; then
  echo "[quality-kit] validate:fast still red after a blocked round — releasing stop; pre-commit and CI will gate." >&2
  exit 0
fi
{ echo "[quality-kit] validate:fast FAILED — fix before ending the turn:"; printf '%s\n' "$out" | tail -40; } >&2
exit 2
