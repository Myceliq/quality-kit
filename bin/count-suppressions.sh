#!/usr/bin/env bash
# What: count lint/type suppression directives in a repo tree, JSON to stdout.
# Where: quality-kit/bin; used by stamp.sh (baseline) and check-drift.sh (budget).
# Why:  "disable the rule" is the classic agent repair-loop shortcut — this
#       makes every new suppression a diff-visible, gated act.
set -euo pipefail
REPO="${1:?usage: count-suppressions.sh <repo>}"
TS=('*.ts' '*.tsx' '*.js' '*.jsx' '*.mjs' '*.cjs' '*.mts' '*.cts')
PY=('*.py')

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

# Every file about to be grepped must be provably readable first. grep's own
# exit code can't be trusted to catch this: once xargs batches several files
# into one invocation, "no match in this batch" (grep exit 1, normal) and "a
# file in this batch errored" (grep exit 2, e.g. permission denied) both fall
# in xargs's blanket "some child exited 1-125" bucket (exit 123) — there's no
# way to tell them apart after the fact, and the `|| true` below exists to
# swallow exactly the harmless one. So check readability up front instead,
# as its own pass with its own unambiguous exit code: a file this script
# cannot read must not silently count as "zero matches found here", which is
# the exact undercount this gate exists to prevent. The loop runs in-process
# per xargs batch (one bash per batch, not one process per file), so this
# stays cheap at scale.
#
# A plain `[ -e "$f" ]` guard would miss a dangling symlink: `-e` follows the
# link and reports false when the target is gone, indistinguishable from a
# path with nothing there at all — but a symlink IS a real tracked git blob
# (its content is the link text), and grep will fail to read through it just
# like any other unreadable file. `-L` sees the link itself regardless of
# where — or whether — it points, so it's checked in addition to `-e`: only a
# path that is NEITHER a symlink NOR an existing target is treated as simply
# absent (a plain `rm` with no `git rm` leaves `--cached` still listing it —
# a normal, common working-tree state, e.g. mid-rename, not a permission
# problem).
#
# "Held to the bar" means `-f` (a readable REGULAR file), not just `-r`: a
# tracked path that resolves to a directory — a gitlink/submodule, or a
# symlink pointing at one — is perfectly "readable" by `-r`, but grep fails
# to open it ("Is a directory") exactly like a permission error would, and
# that failure is just as swallowed by the `|| true` below if not caught here.
if ! (cd "$REPO" && git ls-files -z --cached --others --exclude-standard -- "${TS[@]}" "${PY[@]}" \
    | xargs -0 -r bash -c 'bad=0; for f; do { [ -L "$f" ] || [ -e "$f" ]; } && { [ ! -f "$f" ] || [ ! -r "$f" ]; } && { echo "unreadable: $f" >&2; bad=1; }; done; exit "$bad"' _); then
  echo "cannot count suppressions: an unreadable tracked file would read as zero matches" >&2
  exit 1
fi

# $1 = pattern, remaining = git pathspecs (extension globs). Filenames are
# piped NUL-delimited through xargs -0, never expanded onto grep's own argv:
# a repo with enough tracked files can exceed ARG_MAX, and a single grep
# invocation given every filename as an argument would then fail to even
# start — silently reading as zero matches through the `|| true` below. The
# readability pass above is what makes that `|| true` safe rather than a
# hole: grep can still fail for reasons unrelated to a file's content (its
# own bugs, a signal), but "can't read the file" — the case that matters —
# is already ruled out by the time this runs. xargs batches invocations
# under ARG_MAX automatically.
cnt() {
  local pattern="$1"; shift
  # `git ls-files` prints paths relative to the repo root, so grep must run
  # from there too, or a relative match against the caller's cwd finds nothing.
  (cd "$REPO" && git ls-files -z --cached --others --exclude-standard -- "$@" \
    | xargs -0 -r grep -o -E "$pattern" -- 2>/dev/null \
    | wc -l | tr -d ' ') || true
}
printf '{"oxlint-disable":%s,"ts-expect-error":%s,"ts-ignore":%s,"noqa":%s,"type-ignore":%s}\n' \
  "$(cnt 'oxlint-disable' "${TS[@]}")" \
  "$(cnt '@ts-expect-error' "${TS[@]}")" \
  "$(cnt '@ts-ignore' "${TS[@]}")" \
  "$(cnt '#[[:space:]]*noqa' "${PY[@]}")" \
  "$(cnt '#[[:space:]]*type:[[:space:]]*ignore' "${PY[@]}")"
