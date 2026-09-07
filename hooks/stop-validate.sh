#!/usr/bin/env bash
# What: diff-aware turn-end gate — an agent cannot end its turn with the
#       working tree failing validate:fast.
# Where: stamped as .quality/stop-validate.sh; wired as Claude/Codex Stop hook.
# Why:  closes "agent declares done without checking". exit 2 + stderr is the
#       block protocol in both runtimes. stop_hook_active releases after one
#       blocked round to avoid livelock — pre-commit and CI still gate behind it.
set -uo pipefail
payload="$(cat 2>/dev/null || true)"

# Resolve the repo from the SESSION'S cwd, not the hook process's own.
#
# Both runtimes launch a Stop hook with cwd set to the PROJECT dir, which is not necessarily the
# tree the session edited: a session working in a linked worktree — or in a different repo
# entirely — would otherwise have the project dir validated, and every dirty file there
# attributed to it. On a box where several sessions share one primary checkout, that makes a
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
