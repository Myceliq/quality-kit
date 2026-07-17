#!/usr/bin/env bash
# What: diff-aware turn-end gate — an agent cannot end its turn with the
#       working tree failing validate:fast.
# Where: stamped as .quality/stop-validate.sh; wired as Claude/Codex Stop hook.
# Why:  closes "agent declares done without checking". exit 2 + stderr is the
#       block protocol in both runtimes. stop_hook_active releases after one
#       blocked round to avoid livelock — pre-commit and CI still gate behind it.
set -uo pipefail
payload="$(cat 2>/dev/null || true)"
root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
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
