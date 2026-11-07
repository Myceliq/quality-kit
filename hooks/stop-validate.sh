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
# Preserve pathname newlines while removing only the command's output terminator.
capture_line() {
  local value
  value="$("$@" && printf '.')" || return 1
  value=${value%.}
  REPLY=${value%$'\n'}
}
capture_line python3 -c "import json,sys
try: print(json.load(sys.stdin).get('cwd','') or '')
except Exception: print('')" <<<"$payload" 2>/dev/null || REPLY=""
session_cwd=$REPLY
root=""
if [ -n "$session_cwd" ] && [ -d "$session_cwd" ]; then
  capture_line git -C "$session_cwd" rev-parse --show-toplevel 2>/dev/null && root=$REPLY
fi
if [ -z "$root" ]; then
  capture_line git rev-parse --show-toplevel 2>/dev/null || exit 0
  root=$REPLY
fi
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
physical_dir() { (cd "$1" && cd "$2" && pwd -P); }
common_dir() { # $1=dir inside a work tree → physical absolute path of its git common dir in REPLY
  local g
  capture_line git -C "$1" rev-parse --git-common-dir 2>/dev/null || return 1
  g=$REPLY
  [ -n "$g" ] || return 1
  capture_line physical_dir "$1" "$g" 2>/dev/null
}
capture_line dirname "${BASH_SOURCE[0]}" || exit 0
common_dir "$REPLY" || exit 0
own=$REPLY
common_dir "$root" || exit 0
theirs=$REPLY
[ -n "$own" ] && [ "$own" = "$theirs" ] || exit 0

cd "$root" || exit 0
[ -f .quality-kit.json ] || exit 0

# Skip only if every path in a successful, well-formed status is docs-only. In -z
# format a rename/copy has a second NUL-terminated path (the source).
if python3 -c '
import subprocess, sys
try:
    data = subprocess.check_output(["git", "status", "--porcelain", "-z", "--untracked-files=all"])
    if data and not data.endswith(b"\0"):
        sys.exit(1)
    records = iter(data[:-1].split(b"\0") if data else [])
    # Porcelain v1 XY combinations documented by git-status; unknown means validate.
    statuses = {bytes((x, y)) for x in b"MTARC" for y in b" MTD"} | {
        b" A", b" M", b" T", b" D", b" R", b" C", b"D ",
        b"DD", b"AU", b"UD", b"UA", b"DU", b"AA", b"UU", b"??",
    }
    for record in records:
        if len(record) < 4 or record[2:3] != b" " or record[:2] not in statuses:
            sys.exit(1)
        paths = [record[3:]]
        if b"R" in record[:2] or b"C" in record[:2]:
            paths.append(next(records))
        for path in paths:
            if (any(part in (b"", b".", b"..") for part in path.split(b"/")) or
                    not (path.startswith(b"docs/") or path.endswith((b".md", b".txt")))):
                sys.exit(1)
except Exception:
    sys.exit(1)
' 2>/dev/null; then
  exit 0
fi

if runner="$(python3 -c '
import json, sys
try:
    with open(".quality-kit.json") as f:
        config = json.load(f)
    if not isinstance(config, dict):
        sys.exit(1)
    runner = config.get("runner", "npm")
    if not isinstance(runner, str) or runner not in ("npm", "make"):
        sys.exit(1)
    print(runner)
except Exception:
    sys.exit(1)
' 2>/dev/null)"; then
  case "$runner" in
    npm)  cmd=(npm run --silent validate:fast) ;;
    make) cmd=(make validate-fast) ;;
  esac
  out="$("${cmd[@]}" 2>&1)"; status=$?
else
  out="Invalid or unreadable .quality-kit.json configuration (runner must be npm or make)."
  status=1
fi
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
