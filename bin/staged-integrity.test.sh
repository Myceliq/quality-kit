#!/usr/bin/env bash
# What: tests for staged-integrity.sh and its wiring into hooks/git-pre-commit.
# Where: quality-kit/bin.
# Why:  this is a BLOCKING gate on every stamped repo's commits, and its two
#       failure modes are opposite and both silent — waving a malformed index
#       through, or blocking a clean one across the whole fleet. Every control
#       below is armed in both directions, and every negative arm is re-run with
#       the preflight removed from the hook, because a test that still passes
#       with the feature deleted has asserted nothing.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/staged-integrity.sh"
HOOK="$DIR/../hooks/git-pre-commit"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }

T="$(mktemp -d)"
# The hook `exit 0`s on several paths and this suite runs it repeatedly; if any
# of that ever ends up sourced rather than forked, a suite that exits early
# reports success having asserted nothing (the sibling hook suite was bitten by
# exactly that). Refuse to exit 0 without reaching the end.
SUITE_COMPLETED=0
trap 'rc=$?; rm -rf "$T"
      if [ "$SUITE_COMPLETED" != 1 ]; then
        echo "FAIL harness: the suite exited early (status $rc) without running to completion" >&2
        exit 1
      fi
      exit "$rc"' EXIT

# --- fixtures ----------------------------------------------------------------
# Hostile names, used throughout rather than in one token "hostile" test: spaces,
# a newline, a leading dash and a glob character are what NUL-delimited output
# and `--`/`:(literal)` exist for, and each control must survive them.
SP='a file.txt'
NL=$'new
line.txt'
DASH='-dash.txt'

new_repo() { # → empty git repo, no hook, no stamp
  local r; r="$(mktemp -d "$T/repo.XXXXXX")"
  git -C "$r" init -q
  git -C "$r" config core.hooksPath /dev/null
  git -C "$r" config user.email ci@example.com
  git -C "$r" config user.name ci
  echo "$r"
}

run_script() { # run_script <repo> [VAR=VAL ...] → script exit code, output on stdout
  local r="$1"; shift
  (cd "$r" && env "$@" bash "$SCRIPT") 2>&1
}

script_passes() { # $1=name $2=repo, rest env
  local name="$1" r="$2"; shift 2
  local out rc=0
  out="$(run_script "$r" "$@")" || rc=$?
  [ "$rc" = 0 ] && ok "$name" || bad "$name" "blocked (rc=$rc): $out"
}

script_blocks() { # $1=name $2=repo $3=expected substring, rest env
  local name="$1" r="$2" want="$3"; shift 3
  local out rc=0
  out="$(run_script "$r" "$@")" || rc=$?
  if [ "$rc" = 0 ]; then bad "$name" "allowed: $out"
  elif ! printf '%s' "$out" | grep -qF "$want"; then bad "$name" "blocked, but not for '$want': $out"
  else ok "$name"; fi
}

# --- 1. conflict markers and whitespace --------------------------------------
R="$(new_repo)"; printf 'clean\nfile\n' > "$R/$SP"; git -C "$R" add -- "$SP"
script_passes "clean payload passes" "$R"

R="$(new_repo)"; printf 'a\n<<<<<<< HEAD\nb\n=======\nc\n>>>>>>> other\n' > "$R/$SP"
git -C "$R" add -- "$SP"
script_blocks "conflict marker blocks (path with a space)" "$R" "conflict markers or whitespace"

R="$(new_repo)"; printf 'trailing   \n' > "$R/$NL"; git -C "$R" add -- "$NL"
script_blocks "whitespace error blocks (path with a newline)" "$R" "conflict markers or whitespace"

# --- 2. oversized staged blobs -----------------------------------------------
# The ceiling is overridden to keep the fixtures small; the default is exercised
# by every other repo in this suite passing without an override.
R="$(new_repo)"; head -c 40 /dev/zero > "$R/$DASH"; git -C "$R" add -- "$DASH"
script_passes "under the ceiling passes (leading-dash path)" "$R" QK_MAX_STAGED_BLOB_BYTES=64
script_blocks "over the ceiling blocks (leading-dash path)" "$R" "oversized staged blob" \
  QK_MAX_STAGED_BLOB_BYTES=8

R="$(new_repo)"; head -c 4000 /dev/zero > "$R/big.bin"; git -C "$R" add big.bin
script_passes "a 4 KB blob is nowhere near the documented 2 MiB default" "$R"

# A deletion has no destination blob and must not be measured against the ceiling
# — the whole point of an oversized-file gate is that removing one is the fix.
R="$(new_repo)"; head -c 4000 /dev/zero > "$R/big.bin"; git -C "$R" add big.bin
git -C "$R" commit -q -m init
git -C "$R" rm -q big.bin
script_passes "deleting an oversized file is not itself oversized" "$R" QK_MAX_STAGED_BLOB_BYTES=8

# ...and a big file already in HEAD, untouched by this commit, is not re-judged:
# only what the commit newly introduces is measured.
R="$(new_repo)"; head -c 4000 /dev/zero > "$R/big.bin"; git -C "$R" add big.bin
git -C "$R" commit -q -m init
echo small > "$R/s.txt"; git -C "$R" add s.txt
script_passes "an untouched oversized file in HEAD does not block a later commit" "$R" \
  QK_MAX_STAGED_BLOB_BYTES=8

# A chmod and a rename re-list an existing blob under a new mode or name without
# creating an object. Judging them by size blocks `chmod +x` and `git mv` on a
# legacy oversized file — a state the gate cannot help with and did not create.
R="$(new_repo)"; head -c 4000 /dev/zero > "$R/big.bin"; git -C "$R" add big.bin
git -C "$R" commit -q -m init
chmod +x "$R/big.bin"; git -C "$R" add big.bin
script_passes "chmod on an existing oversized file introduces no blob" "$R" \
  QK_MAX_STAGED_BLOB_BYTES=8

R="$(new_repo)"; head -c 4000 /dev/zero > "$R/big.bin"; git -C "$R" add big.bin
git -C "$R" commit -q -m init
git -C "$R" mv big.bin moved.bin
script_passes "renaming an existing oversized file introduces no blob" "$R" \
  QK_MAX_STAGED_BLOB_BYTES=8

# A malformed ceiling must fall back, not abort: `set -e` plus `-gt` makes a typo
# fatal, and this hook is global — one bad value would freeze commits everywhere.
R="$(new_repo)"; echo x > "$R/s.txt"; git -C "$R" add s.txt
out="$(run_script "$R" QK_MAX_STAGED_BLOB_BYTES=2MB)" && \
  printf '%s' "$out" | grep -q "not an integer this can compare against" \
  && ok "a malformed ceiling falls back with a notice instead of freezing commits" \
  || bad "a malformed ceiling falls back with a notice instead of freezing commits" "$out"

# Digits alone are not enough: past int64, `[ ... -gt ... ]` fails with "integer
# expression expected", and inside an `if` that failure is exempt from `set -e`
# and simply reads as FALSE — every oversized blob sails through a gate that
# looks configured. The 3 MB payload is what makes the arm discriminating: it has
# to be refused by the default the malformed value falls back to.
R="$(new_repo)"; head -c 3000000 /dev/zero > "$R/huge.bin"; git -C "$R" add huge.bin
script_blocks "an out-of-range ceiling falls back to the default rather than reading as false" \
  "$R" "oversized staged blob" QK_MAX_STAGED_BLOB_BYTES=99999999999999999999999

# `[ ... -gt 0100 ]` reads 0100 as OCTAL 64 — a ceiling that silently means
# something other than what it says. 70 bytes sits between the two readings.
R="$(new_repo)"; head -c 70 /dev/zero > "$R/mid.bin"; git -C "$R" add mid.bin
script_passes "a leading-zero ceiling is read as decimal, not octal" "$R" \
  QK_MAX_STAGED_BLOB_BYTES=0100

# --- 3. case-fold collisions --------------------------------------------------
R="$(new_repo)"; echo a > "$R/${DASH}"; echo b > "$R/-DASH.txt"
git -C "$R" add -- "$DASH" -DASH.txt
script_blocks "case-fold collision blocks (leading-dash paths)" "$R" "case-fold collision"

# Half the pair is in HEAD and never appears in the staged diff — the check runs
# over the post-index tracked set for exactly this case.
R="$(new_repo)"; echo a > "$R/README.md"; git -C "$R" add README.md; git -C "$R" commit -q -m init
echo b > "$R/readme.MD"; git -C "$R" add readme.MD
script_blocks "collision against a path already committed blocks" "$R" "case-fold collision"

R="$(new_repo)"; mkdir -p "$R/src"; echo a > "$R/src/a.txt"; echo b > "$R/src/B.txt"
git -C "$R" add src
script_passes "paths that differ in more than case do not collide" "$R"

# --- 4. symlinks --------------------------------------------------------------
R="$(new_repo)"; echo t > "$R/target.txt"; ln -s target.txt "$R/$SP"
git -C "$R" add -- target.txt "$SP"
script_passes "symlink to a staged target passes (link name with a space)" "$R"

R="$(new_repo)"; ln -s target.txt "$R/$SP"; git -C "$R" add -- "$SP"
script_blocks "symlink to an untracked target blocks" "$R" "broken symlink"

# The target exists on disk but is not in the index — the commit still contains a
# link to nothing, which is precisely why existence is asked of the index.
R="$(new_repo)"; echo t > "$R/target.txt"; ln -s target.txt "$R/lnk"
printf 'target.txt\n' > "$R/.gitignore"
git -C "$R" add .gitignore lnk
script_blocks "a target present only in the working tree is still broken" "$R" "broken symlink"

R="$(new_repo)"; mkdir -p "$R/src"; echo a > "$R/src/a.txt"; ln -s src "$R/lnk"
git -C "$R" add src lnk
script_passes "symlink to a tracked directory passes" "$R"

R="$(new_repo)"; mkdir -p "$R/a/b"; echo t > "$R/a/t.txt"; ln -s ../t.txt "$R/a/b/lnk"
git -C "$R" add a
script_passes "relative target with .. resolves against the link's own directory" "$R"

R="$(new_repo)"; mkdir -p "$R/a/b"; echo t > "$R/a/t.txt"; ln -s ../nope.txt "$R/a/b/lnk"
git -C "$R" add a
script_blocks "relative target with .. that misses blocks" "$R" "broken symlink"

# Out-of-repo targets are not the index's business, in either direction: an
# absolute path and one that climbs above the root are both left alone.
R="$(new_repo)"; ln -s /etc/hostname "$R/abs"; ln -s ../../outside "$R/up"
git -C "$R" add abs up
script_passes "absolute and repo-escaping targets are left alone" "$R"

# A target containing glob characters must be matched literally, or the pathspec
# finds some other file and the broken link is waved through.
R="$(new_repo)"; ln -s 'we*rd.txt' "$R/glob"; echo real > "$R/weird.txt"
git -C "$R" add glob weird.txt
script_blocks "a glob-shaped target is matched literally, not expanded" "$R" "broken symlink"

# Removing the TARGET breaks a link that is not itself staged and never appears
# in the diff — a staged-only walk accepts a commit whose result is broken.
R="$(new_repo)"; echo t > "$R/target.txt"; ln -s target.txt "$R/lnk"
git -C "$R" add target.txt lnk; git -C "$R" commit -q -m init
git -C "$R" rm -q target.txt
script_blocks "deleting the target of a committed link blocks" "$R" "broken symlink"

R="$(new_repo)"; echo t > "$R/target.txt"; ln -s target.txt "$R/lnk"
git -C "$R" add target.txt lnk; git -C "$R" commit -q -m init
git -C "$R" mv target.txt renamed.txt
script_blocks "renaming the target of a committed link blocks" "$R" "broken symlink"

# Git removes FILES, never directories: emptying a tracked directory breaks a
# link pointing at it while the directory's own name appears nowhere in the diff.
R="$(new_repo)"; mkdir -p "$R/d"; echo a > "$R/d/a.txt"; ln -s d "$R/lnk"
git -C "$R" add d lnk; git -C "$R" commit -q -m init
git -C "$R" rm -q d/a.txt
script_blocks "emptying the directory a link points at blocks" "$R" "broken symlink"

# ...and removing only SOME of that directory's contents leaves the link fine —
# marking ancestors widens what gets looked at, not what gets refused.
R="$(new_repo)"; mkdir -p "$R/d"; echo a > "$R/d/a.txt"; echo b > "$R/d/b.txt"
ln -s d "$R/lnk"
git -C "$R" add d lnk; git -C "$R" commit -q -m init
git -C "$R" rm -q d/a.txt
script_passes "removing one file from a linked directory leaves the link valid" "$R"

# ...but a link that was ALREADY broken when it was committed is not re-judged on
# every later commit. Re-judging it would leave the repo unable to commit anything
# without --no-verify, and a gate people switch off is worse than the defect.
# It deletes something, so the index walk really runs and really sees the link —
# the arm would pass vacuously if the commit removed nothing.
R="$(new_repo)"; ln -s generated/out "$R/lnk"
printf 'generated/\n' > "$R/.gitignore"; echo x > "$R/unrelated.txt"
git -C "$R" add .gitignore lnk unrelated.txt
git -C "$R" commit -q -m "committed while the gate was not looking"
git -C "$R" rm -q unrelated.txt
script_passes "a pre-existing broken link does not block a commit that removes something else" "$R"

# A target really ending in a newline is a different path from one that does not.
# `$(git cat-file blob ...)` strips it, so the link would be checked as 'target.txt'
# — passing on a broken link precisely because the valid path happens to be tracked.
R="$(new_repo)"; echo t > "$R/target.txt"; ln -s $'target.txt\n' "$R/lnk"
git -C "$R" add target.txt lnk
script_blocks "a target with a trailing newline is not trimmed into a valid one" "$R" "broken symlink"

# 4b. flattening: Git state establishes it exactly — the index mode changed.
R="$(new_repo)"; echo t > "$R/target.txt"; ln -s target.txt "$R/lnk"
git -C "$R" add target.txt lnk; git -C "$R" commit -q -m init
rm "$R/lnk"; echo t > "$R/lnk"; git -C "$R" add lnk
script_blocks "a symlink flattened into a regular file blocks" "$R" "flattened symlink"

# ...and the reverse conversion, a file deliberately turned INTO a symlink, is
# not a flattening and must not be caught by it.
R="$(new_repo)"; echo t > "$R/target.txt"; echo t > "$R/lnk"
git -C "$R" add target.txt lnk; git -C "$R" commit -q -m init
rm "$R/lnk"; ln -s target.txt "$R/lnk"; git -C "$R" add lnk
script_passes "converting a file into a valid symlink is allowed" "$R"

# --- the hook wiring: armed paired probes ------------------------------------
# Everything above proves the script. These prove the GATE: that the preflight
# runs inside hooks/git-pre-commit, before validate:fast and before the reviewer
# is invoked — and that each negative arm reaches the reviewer once the preflight
# is removed from the hook.
FBIN="$T/fakebin"; mkdir -p "$FBIN"
cat > "$FBIN/codex" <<'FAKE'
#!/usr/bin/env bash
# Records that a review was requested, then behaves as an empty (fail-open) run,
# so the hook's own verdict logic never decides the outcome of these probes.
echo invoked >> "$REVIEWER_LOG"
output_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) output_file="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$output_file" ] && : > "$output_file"
exit 0
FAKE
chmod +x "$FBIN/codex"

# The hook with the preflight disabled — the break probe. The one line that calls
# the script is replaced by a no-op (rather than deleted, which would leave an
# empty `if` body and a syntax error that reads as "blocked" for the wrong
# reason). Three assertions on the probe itself, because a break probe that is
# quietly a no-op makes every arm below meaningless: it must differ from the
# hook, must not still contain the invocation, and must still parse.
BROKEN_HOOK="$T/git-pre-commit.no-preflight"
awk 'index($0, "bash \"$QK_INTEGRITY\" || exit 1") { $0 = "    :" } { print }' "$HOOK" > "$BROKEN_HOOK"
if ! cmp -s "$HOOK" "$BROKEN_HOOK" \
   && ! grep -qF 'bash "$QK_INTEGRITY" || exit 1' "$BROKEN_HOOK" \
   && bash -n "$BROKEN_HOOK"; then
  ok "break-probe hook really has the preflight disabled"
else
  bad "break-probe hook really has the preflight disabled" "the probe did not change the hook, still calls the preflight, or no longer parses — every break probe below would be meaningless"
fi

stamped_repo() { # → stamped repo whose validate:fast records that it ran
  local r; r="$(new_repo)"
  printf '{"version":"0.1.0","profile":"python","runner":"make","pendingFlags":[]}' > "$r/.quality-kit.json"
  printf 'validate-fast:\n\t@touch %s/.validate-fast-ran\n' "$r" > "$r/Makefile"
  git -C "$r" add .quality-kit.json Makefile
  git -C "$r" commit -q -m stamp
  echo "$r"
}

run_hook() { # run_hook <repo> <hook> [VAR=VAL ...] → rc; sets $HOOK_OUT
  local r="$1" hook="$2"; shift 2
  local rc=0
  rm -f "$r/.validate-fast-ran" "$r/.reviewer-log"
  HOOK_OUT="$( (cd "$r" && env PATH="$FBIN:$PATH" REVIEWER_LOG="$r/.reviewer-log" \
      XDG_STATE_HOME="$T/state" "$@" bash "$hook") 2>&1 )" || rc=$?
  return "$rc"
}

# Each control: clean payload commits and is reviewed; the SAME fixture with only
# the payload changed to the defect is refused before validate:fast and before
# the reviewer; the same defect with the preflight removed reaches the reviewer.
probe() { # probe <name> <repo-with-clean-payload> <break-fn> [VAR=VAL ...]
  local name="$1" r="$2" breakfn="$3"; shift 3
  local rc=0

  run_hook "$r" "$HOOK" "$@" || rc=$?
  { [ "$rc" = 0 ] && [ -f "$r/.reviewer-log" ] && [ -f "$r/.validate-fast-ran" ]; } \
    && ok "$name: clean payload is validated and reviewed" \
    || bad "$name: clean payload is validated and reviewed" \
           "rc=$rc reviewer=$([ -f "$r/.reviewer-log" ] && echo yes || echo no) vf=$([ -f "$r/.validate-fast-ran" ] && echo yes || echo no) $HOOK_OUT"

  "$breakfn" "$r"

  rc=0; run_hook "$r" "$HOOK" "$@" || rc=$?
  { [ "$rc" != 0 ] && [ ! -f "$r/.reviewer-log" ] && [ ! -f "$r/.validate-fast-ran" ]; } \
    && ok "$name: the defect is refused before validate:fast and before the reviewer" \
    || bad "$name: the defect is refused before validate:fast and before the reviewer" \
           "rc=$rc reviewer=$([ -f "$r/.reviewer-log" ] && echo yes || echo no) vf=$([ -f "$r/.validate-fast-ran" ] && echo yes || echo no) $HOOK_OUT"

  rc=0; run_hook "$r" "$BROKEN_HOOK" "$@" || rc=$?
  { [ "$rc" = 0 ] && [ -f "$r/.reviewer-log" ]; } \
    && ok "$name: BREAK PROBE — without the preflight the same defect reaches the reviewer" \
    || bad "$name: BREAK PROBE — without the preflight the same defect reaches the reviewer" \
           "rc=$rc reviewer=$([ -f "$r/.reviewer-log" ] && echo yes || echo no) $HOOK_OUT"
}

# 1. conflict marker, in a path with a space.
R="$(stamped_repo)"; printf 'a\nb\n' > "$R/$SP"; git -C "$R" add -- "$SP"
break_conflict() { printf 'a\n<<<<<<< HEAD\nb\n=======\nc\n>>>>>>> other\n' > "$1/$SP"; git -C "$1" add -- "$SP"; }
probe "conflict marker" "$R" break_conflict

# 2. oversized blob, in a path with a newline.
R="$(stamped_repo)"; head -c 16 /dev/zero > "$R/$NL"; git -C "$R" add -- "$NL"
break_oversize() { head -c 200 /dev/zero > "$1/$NL"; git -C "$1" add -- "$NL"; }
probe "oversized blob" "$R" break_oversize QK_MAX_STAGED_BLOB_BYTES=64

# 3. case-fold collision, on leading-dash paths.
R="$(stamped_repo)"; echo a > "$R/$DASH"; git -C "$R" add -- "$DASH"
break_case() { echo b > "$1/-DASH.txt"; git -C "$1" add -- -DASH.txt; }
probe "case-fold collision" "$R" break_case

# 4. symlink whose target leaves the commit, link name with a space.
R="$(stamped_repo)"; echo t > "$R/target.txt"; ln -s target.txt "$R/$SP"
git -C "$R" add -- target.txt "$SP"
break_symlink() { git -C "$1" rm -q --cached target.txt; }
probe "broken symlink" "$R" break_symlink

# An unstamped repo is untouched: the kit's deterministic tier is opt-in via the
# stamp, and this preflight sits inside it rather than gating the whole box.
R="$(new_repo)"; printf 'a\n<<<<<<< HEAD\nb\n' > "$R/conflict.txt"; git -C "$R" add conflict.txt
rc=0; run_hook "$R" "$HOOK" || rc=$?
{ [ "$rc" = 0 ] && [ -f "$R/.reviewer-log" ]; } \
  && ok "an unstamped repo is not gated by the preflight" \
  || bad "an unstamped repo is not gated by the preflight" "rc=$rc $HOOK_OUT"

# A stamped repo whose kit checkout has no staged-integrity.sh must still commit —
# a global hook that freezes every commit because one file was not copied is worse
# than the defects it screens for — but the skip has to be MACHINE-readable, or it
# is the human-readable sentence nobody reads in an agent-driven repo, which is the
# failure the GATE_SKIPPED contract was added to end.
MISSING_KIT="$T/kit-without-script"; mkdir -p "$MISSING_KIT/hooks" "$MISSING_KIT/bin"
cp "$HOOK" "$MISSING_KIT/hooks/git-pre-commit"
SKIPLOG="$T/state/quality-kit/gate-skips.log"

R="$(stamped_repo)"; printf 'a\n<<<<<<< HEAD\nb\n' > "$R/conflict.txt"; git -C "$R" add conflict.txt
rc=0; run_hook "$R" "$MISSING_KIT/hooks/git-pre-commit" || rc=$?
{ [ "$rc" = 0 ] && printf '%s' "$HOOK_OUT" | grep -q "PREFLIGHT_SKIPPED reason=preflight_missing"; } \
  && ok "a missing preflight emits the machine-readable skip and does not freeze commits" \
  || bad "a missing preflight emits the machine-readable skip and does not freeze commits" "rc=$rc $HOOK_OUT"

# Same log, same five columns, its own class — a census is only possible with one
# schema, and `install_failure` keeps this row out of both existing queries. It is
# not the LAST row: the fake reviewer writes nothing, so the review gate files its
# own empty_output skip underneath, which is the two records staying distinguishable.
grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z[[:space:]]+preflight_missing[[:space:]].*install_failure$' \
  "$SKIPLOG" 2>/dev/null \
  && ok "the preflight skip lands in gate-skips.log with its own reason and class" \
  || bad "the preflight skip lands in gate-skips.log with its own reason and class" \
         "log tail: $(tail -n 2 "$SKIPLOG" 2>/dev/null || echo MISSING)"

# ...and it must NOT masquerade as an unreviewed commit. The reviewer ran here, so
# filing this as a GATE_SKIPPED would put a "never reviewed" row in the log for a
# commit that WAS reviewed — exactly what that log is counted for.
if printf '%s' "$HOOK_OUT" | grep -q "GATE_SKIPPED reason=preflight_missing"; then
  bad "a preflight skip is not filed as a review skip" "it emitted GATE_SKIPPED reason=preflight_missing"
else
  ok "a preflight skip is not filed as a review skip"
fi
[ -f "$R/.reviewer-log" ] \
  && ok "the reviewer still runs when only the preflight is missing" \
  || bad "the reviewer still runs when only the preflight is missing" "$HOOK_OUT"

# A repo that declared it wants a real gate gets one. Not-installed is not a blip:
# it recurs on every commit until someone copies the file — sandbox_init's shape,
# not an unreviewable diff's — so strict mode refuses it, before the reviewer.
R="$(stamped_repo)"; echo x > "$R/f.txt"; git -C "$R" add f.txt
rc=0; run_hook "$R" "$MISSING_KIT/hooks/git-pre-commit" REVIEW_HOOK_REQUIRE_GATE=1 || rc=$?
{ [ "$rc" != 0 ] && [ ! -f "$R/.reviewer-log" ] && [ ! -f "$R/.validate-fast-ran" ]; } \
  && ok "REVIEW_HOOK_REQUIRE_GATE=1 refuses a commit whose preflight is missing" \
  || bad "REVIEW_HOOK_REQUIRE_GATE=1 refuses a commit whose preflight is missing" \
         "rc=$rc reviewer=$([ -f "$R/.reviewer-log" ] && echo yes || echo no) $HOOK_OUT"

# The strict switch travels with the stamp, so a fresh clone or a CI runner that
# never sourced anyone's profile refuses it too.
R="$(stamped_repo)"
printf '{"version":"0.1.0","profile":"python","runner":"make","pendingFlags":[],"requireGate":true}' \
  > "$R/.quality-kit.json"
git -C "$R" add .quality-kit.json
rc=0; run_hook "$R" "$MISSING_KIT/hooks/git-pre-commit" || rc=$?
[ "$rc" != 0 ] \
  && ok "requireGate in .quality-kit.json refuses a missing preflight too" \
  || bad "requireGate in .quality-kit.json refuses a missing preflight too" "rc=$rc $HOOK_OUT"

SUITE_COMPLETED=1
[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
