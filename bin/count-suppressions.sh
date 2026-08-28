#!/usr/bin/env bash
# What: count lint/type suppression directives in a repo tree, JSON to stdout.
# Where: quality-kit/bin; used by stamp.sh (baseline) and check-drift.sh (budget).
# Why:  "disable the rule" is the classic agent repair-loop shortcut — this
#       makes every new suppression a diff-visible, gated act.
set -euo pipefail
REPO="${1:?usage: count-suppressions.sh <repo>}"

# Enumerate via `git ls-files --cached --others --exclude-standard`, matching
# loc-budget.sh's approach, not `grep -r .` with a hardcoded --exclude-dir
# list. Two flags, two distinct jobs — do not collapse them:
#   - A nested checkout (an agent worktree under .claude/worktrees/, say) is
#     excluded by git's REPOSITORY BOUNDARY, not by .gitignore: `ls-files`
#     never descends into a directory that holds its own `.git`, ignored or
#     not. This is the mechanism that fixes #12, and it holds even in a repo
#     that never gitignores its worktree dir (verified empirically).
#   - `--exclude-standard` excludes everything else `.gitignore` covers that
#     is NOT a separate repo — node_modules, build output, vendored source.
#     This is the job the old hardcoded --exclude-dir list used to do; drop
#     the flag and those come flooding back in.
#   - `--cached` alone would find both of the above, but would also silently
#     drop a real file that's been written but not yet `git add`ed. `--others`
#     restores that on-disk file, so a file is excluded only for being
#     ignored or genuinely absent, never merely unstaged.
# A failed enumeration is a loud exit, not a silent zero — a counter that
# undercounts is exactly the miss this gate exists to catch.
if ! git -C "$REPO" ls-files -z --cached --others --exclude-standard >/dev/null; then
  echo "cannot enumerate tracked files: git ls-files failed here" >&2
  exit 1
fi

# $1 = pattern, remaining = git pathspecs (extension globs). Filenames are
# piped NUL-delimited through xargs -0, never expanded onto grep's own argv:
# a repo with enough tracked files can exceed ARG_MAX, and a single grep
# invocation given every filename as an argument would then fail to even
# start — silently reading as zero matches through the `|| true` below.
# xargs batches invocations under that limit automatically.
cnt() {
  local pattern="$1"; shift
  # `git ls-files` prints paths relative to the repo root, so grep must run
  # from there too, or a relative match against the caller's cwd finds nothing.
  (cd "$REPO" && git ls-files -z --cached --others --exclude-standard -- "$@" \
    | xargs -0 -r grep -o -E "$pattern" -- 2>/dev/null \
    | wc -l | tr -d ' ') || true
}
TS=('*.ts' '*.tsx' '*.js' '*.jsx' '*.mjs' '*.cjs' '*.mts' '*.cts')
PY=('*.py')
printf '{"oxlint-disable":%s,"ts-expect-error":%s,"ts-ignore":%s,"noqa":%s,"type-ignore":%s}\n' \
  "$(cnt 'oxlint-disable' "${TS[@]}")" \
  "$(cnt '@ts-expect-error' "${TS[@]}")" \
  "$(cnt '@ts-ignore' "${TS[@]}")" \
  "$(cnt '#[[:space:]]*noqa' "${PY[@]}")" \
  "$(cnt '#[[:space:]]*type:[[:space:]]*ignore' "${PY[@]}")"
