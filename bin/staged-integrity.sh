#!/usr/bin/env bash
# What:  deterministic staged-INDEX integrity preflight — conflict markers and
#        whitespace, oversized new blobs, case-fold path collisions, broken and
#        flattened symlinks.
# Where: quality-kit/bin; called by hooks/git-pre-commit immediately before the
#        stamped repo's own validate:fast, so it lands before any model review.
# Why:   validate:fast is a LANGUAGE gate — Pyright, Ruff, tsc, a SLOC budget.
#        None of them see a conflict marker in a markdown prompt, a 40 MB binary
#        whose textual diff is two lines, or a path pair that collides on a
#        case-insensitive checkout. Those defects reach the commit AND spend a
#        review call on the way. They are language-independent, so they belong
#        in one kit-owned script rather than in each profile.
#
# Everything here reads the INDEX — `git ls-files`, `git diff --cached`,
# `git cat-file` — and never the working tree. This gate certifies what the
# commit will CONTAIN, and the two diverge the moment anything is staged
# partially (`git add -p`) or edited after `git add`. A worktree read would
# certify a file the commit does not include.
#
# All git output is NUL-delimited and every path is passed with `--` (and
# `:(literal)` where it is a pathspec), so filenames containing spaces,
# newlines, glob characters or a leading dash are handled rather than split,
# globbed or read as options.
set -euo pipefail

# This gate is BYTE-oriented end to end — git paths are bytes, its output is
# NUL-delimited, and `git cat-file --batch` reports blob sizes in bytes. Under a
# UTF-8 locale bash's `read -N` counts CHARACTERS instead, so a symlink target
# carrying any non-ASCII byte desyncs the batch reader below: `ln -s café.txt lnk`
# is 9 bytes but 8 characters, `read -N 9` eats the newline `--batch` writes after
# the contents, the following `read _` hits EOF and returns 1, and — a plain
# command in a while body under `set -e` — this script dies with NO output, which
# the hook turns into a SILENT refusal of a valid commit. Measured on one staged
# index: exit 1 under en_US.UTF-8, exit 0 under C. Set once, here, rather than at
# each read: nothing in this file wants character semantics.
export LC_ALL=C

# --- size ceiling ------------------------------------------------------------
# 2 MiB. Nothing a human writes reaches it: it clears the largest lockfiles and
# committed test fixtures in the fleet by a wide margin, while a binary, a
# vendored archive or a captured trace blows straight through it. The number is
# a policy, not a discovery — raise it per repo with QK_MAX_STAGED_BLOB_BYTES.
#
# A malformed value falls back with a notice instead of aborting: `set -e` plus
# the `-gt` below makes a typo fatal, and this hook is global, so one bad value
# would freeze commits everywhere. Same reasoning as review_hook_int_knob().
MAX_BLOB_BYTES_DEFAULT=2097152
MAX_BLOB_BYTES="${QK_MAX_STAGED_BLOB_BYTES:-$MAX_BLOB_BYTES_DEFAULT}"
# Leading zeros are stripped BEFORE the value is used, because `[ ... -gt 010 ]`
# reads 010 as octal 8 — a ceiling that silently means something other than what
# it says. Digits alone are not enough either: a value past int64 makes `[` fail
# with "integer expression expected", and inside an `if` that error is exempt
# from `set -e` and simply reads as false, so every oversized blob would sail
# through a gate that looked configured. 18 digits is the widest that cannot
# overflow.
while [ "${#MAX_BLOB_BYTES}" -gt 1 ] && [ "${MAX_BLOB_BYTES#0}" != "$MAX_BLOB_BYTES" ]; do
  MAX_BLOB_BYTES="${MAX_BLOB_BYTES#0}"
done
case "$MAX_BLOB_BYTES" in
  ''|*[!0-9]*|??????????????????*)
    echo "[staged-integrity] QK_MAX_STAGED_BLOB_BYTES='${QK_MAX_STAGED_BLOB_BYTES-}' is not an integer this can compare against — using ${MAX_BLOB_BYTES_DEFAULT}." >&2
    MAX_BLOB_BYTES="$MAX_BLOB_BYTES_DEFAULT"
    ;;
esac

FOUND=0
fail() { FOUND=1; printf '[staged-integrity] %s\n' "$@" >&2; }

# --- 1. conflict markers and whitespace errors -------------------------------
# git's own check, so `core.whitespace` and `.gitattributes` remain the way to
# tune it per repo — a second knob here would just be a worse copy of those.
if ! check_out="$(git diff --cached --check 2>&1)"; then
  fail "conflict markers or whitespace errors in the staged content:"
  printf '%s\n' "$check_out" | sed 's/^/[staged-integrity]   /' >&2
fi

# --- 2 & 4b. staged blob sizes, and symlinks flattened into regular files -----
# `--raw -z` gives both index modes and the destination blob id per change, so
# the size comes from the object store rather than from `stat` on a file the
# index may not match. Only NEW content is measured: a deletion carries no
# destination blob, a path already in HEAD and unchanged never appears in this
# diff at all, and a record whose two blob ids are equal (a chmod, a rename, a
# copy) introduces no object.
LINK_PATHS=()   # symlinks this commit is answerable for, checked in 4a below
LINK_SHAS=()
LINK_STAGED=()  # 1 = staged by this commit, 0 = pre-existing, target removed
declare -A SEEN_LINKS=()
declare -A REMOVED=()  # paths this commit takes out of the tracked set

# Ancestors too. Git removes FILES; a directory disappears from the tracked set
# only as a side effect of its last file going, and never appears in the raw diff
# under its own name — so a link pointing at `d/` survives `git rm d/only-file`
# unnoticed unless `d` is marked as well. This only widens the set of links worth
# LOOKING at; whether one is really broken is still decided by asking the index.
mark_removed() {
  local p="$1"
  while [ -n "$p" ]; do
    REMOVED["$p"]=1
    [ "$p" = "${p%/*}" ] && break
    p="${p%/*}"
  done
}

while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
  read -r srcmode dstmode srcsha dstsha status <<<"${meta#:}"
  # R/C records carry source AND destination paths; the destination is the one
  # this commit adds, and the SOURCE is one it removes.
  case "$status" in
    R*|C*)
      srcpath="$path"
      IFS= read -r -d '' path || break
      # A copy leaves its source in place; a rename does not.
      if [ "$status" = "${status#C}" ]; then mark_removed "$srcpath"; fi
      ;;
  esac

  if [ "$status" = "D" ]; then mark_removed "$path"; continue; fi
  case "$dstsha" in *[!0]*) ;; *) continue ;; esac  # unmerged entry: no blob yet

  # 120000 -> anything-but-120000 is a symlink that got flattened, which Git
  # state establishes exactly: the index mode changed. This is what a tool that
  # copies through links (an installer, an editor "save as", a naive rsync)
  # leaves behind, and it is invisible in the textual diff — the file's contents
  # simply become the target's contents.
  if [ "$srcmode" = "120000" ] && [ "$dstmode" != "120000" ]; then
    fail "flattened symlink: '${path}' was a symlink in HEAD and is staged as mode ${dstmode}." \
         "  Restore the link (git checkout HEAD -- <path>) or drop it deliberately."
  fi

  [ "$dstmode" = "160000" ] && continue  # gitlink: the object lives in the submodule

  # Same blob id on both sides = no new content: a chmod, a rename, a copy. The
  # object already exists and the commit adds nothing to the repository's weight,
  # so measuring it would block `git mv` and `chmod +x` on a legacy oversized file
  # — a state the gate cannot help with and did not create.
  if [ "$dstsha" != "$srcsha" ]; then
    if ! size="$(git cat-file -s "$dstsha" 2>/dev/null)"; then
      fail "staged blob for '${path}' is unreadable (${dstsha}) — the index is inconsistent."
      continue
    fi
    if [ "$size" -gt "$MAX_BLOB_BYTES" ]; then
      fail "oversized staged blob: '${path}' is ${size} bytes, over the ${MAX_BLOB_BYTES}-byte ceiling." \
           "  Keep it out of git, or raise QK_MAX_STAGED_BLOB_BYTES for this repo."
    fi
  fi

  if [ "$dstmode" = "120000" ]; then
    SEEN_LINKS["$path"]=1
    LINK_PATHS+=("$path")
    LINK_SHAS+=("$dstsha")
    LINK_STAGED+=(1)
  fi
done < <(git diff --cached --raw -z --abbrev=40)

# --- 3. case-fold collisions in the post-index tracked path set ---------------
# The index IS the tracked path set of the commit being made, so the check runs
# over all of it, not only over what is staged: the collision is between the new
# path and an OLD one, and half of the pair is never in the diff. Two paths that
# differ only in case check out onto one file on macOS and Windows — the second
# clobbers the first, silently, on a machine that is not the author's.
if ! collisions="$(git ls-files -z | LC_ALL=C awk '
    BEGIN { RS = "\0" }
    { k = tolower($0)
      if (k in seen) { if (seen[k] != $0) { print seen[k]; print $0; bad = 1 } }
      else seen[k] = $0 }
    END { exit (bad ? 1 : 0) }')"; then
  fail "case-fold collision — these paths become one file on a case-insensitive checkout:"
  printf '%s\n' "$collisions" | sed 's/^/[staged-integrity]   /' >&2
fi
# ponytail: ASCII fold (LC_ALL=C tolower), and the whole path folded as one
# string. It catches the pair that actually loses data — two files landing on
# one path. It does NOT catch `src/` vs `Src/`, where the files coexist and only
# the directory's case is ambiguous. Fold per path component against a real
# Unicode case-folding table if a repo ever meets that in earnest.

# --- 4a. symlinks whose target is absent from the commit ----------------------
# The link's blob content IS its target text, so the target is read from the
# object store. Existence is asked of the index — `git ls-files` — because a
# target that exists only in the working tree (gitignored, generated, never
# added) is precisely the defect: the commit contains a link to nothing.
#
# A pathspec matches a directory prefix, so a link pointing at a tracked
# DIRECTORY resolves through the same query without enumerating it.
# Answers into $RESOLVED rather than on stdout, because `x="$(f)"` strips trailing
# newlines and a target may legitimately end in one — the same trimming bug as
# reading the blob through a command substitution, one layer up.
RESOLVED=""
resolve_in_repo() { # $1=link path  $2=target → $RESOLVED, or 1 if outside the repo
  local link="$1" target="$2" dir="" combined part
  RESOLVED=""
  case "$target" in /*) return 1 ;; esac  # absolute: outside the index's remit
  case "$link" in */*) dir="${link%/*}/" ;; esac
  combined="${dir}${target}"

  local -a stack=()
  # Split on `/` by reading NUL-free fields rather than word-splitting, which
  # would glob a target containing `*` and mangle one containing a newline.
  while IFS= read -r -d '/' part; do
    case "$part" in
      ''|.) ;;
      ..)   [ "${#stack[@]}" -gt 0 ] || return 1  # escapes the repo root
            unset 'stack[${#stack[@]}-1]' ;;
      *)    stack+=("$part") ;;
    esac
  done < <(printf '%s/' "$combined")
  [ "${#stack[@]}" -gt 0 ] || return 1

  local IFS=/
  RESOLVED="${stack[*]}"
}

# A link is judged when this commit STAGES it, and also when this commit REMOVES
# what it points at — deleting or renaming a target leaves the link itself out of
# the diff entirely, so a staged-only walk accepts a commit whose result contains
# a broken link. Both are defects this commit introduces.
#
# What it deliberately does NOT do is re-judge every link on every commit. A repo
# that already committed a link into gitignored or generated territory would then
# be unable to commit anything at all until someone reached for --no-verify, and
# a gate people have to switch off is worse than the defect. Same reason the size
# ceiling only measures what the commit newly introduces.
if [ "${#REMOVED[@]}" -gt 0 ]; then
  while IFS= read -r -d '' entry; do
    # `<mode> <sha> <stage>\t<path>` — fixed-width mode and sha, then the path,
    # which may contain anything including a tab, so it is taken as the whole
    # remainder after the FIRST tab.
    [ "${entry:0:6}" = "120000" ] || continue
    link_path="${entry#*$'\t'}"
    [ -n "${SEEN_LINKS[$link_path]:-}" ] && continue
    SEEN_LINKS["$link_path"]=1
    LINK_PATHS+=("$link_path")
    LINK_SHAS+=("${entry:7:40}")
    LINK_STAGED+=(0)
  done < <(git ls-files -s -z)
fi

# Targets are read with `git cat-file --batch`: one process for every link, and —
# the reason it is not `$(git cat-file blob ...)` — the EXACT bytes. Command
# substitution strips trailing newlines, so a link whose real target is "x\n"
# would be checked as "x": broken links pass when "x" happens to be tracked, and
# valid ones fail. `read -N <size>` takes the blob verbatim, newlines included.
#
# LC_ALL=C over the whole loop, because `--batch` reports the size in BYTES while
# `read -N` consumes that many CHARACTERS. In a UTF-8 locale any non-ASCII byte in
# a target desyncs the stream: `ln -s café.txt lnk` is 9 bytes but 8 characters, so
# `read -N 9` eats the newline `--batch` writes after the contents, the following
# `read _` hits EOF and returns 1, and — a plain command in a while body under
# `set -e` — the script dies with NO output at all, which the hook turns into a
# SILENT refusal of a valid commit. Measured on one staged index: exit 1 under
# en_US.UTF-8, exit 0 under C. With two or more links it desyncs rather than
# ending, and the next record's contents are parsed as a header, firing a bogus
# "has no readable blob". Set once around the loop rather than per-read: every
# read in here is over the same byte stream.
LINK_TARGETS=()
if [ "${#LINK_SHAS[@]}" -gt 0 ]; then
  i=0
  while IFS= read -r header; do
    size="${header##* }"
    case "$size" in
      ''|*[!0-9]*)  # "<sha> missing": the index points at an object that is gone
        fail "staged symlink '${LINK_PATHS[$i]}' has no readable blob (${header})."
        LINK_TARGETS[i]=""
        ;;
      *)
        target=""
        [ "$size" -gt 0 ] && IFS= read -r -N "$size" target
        IFS= read -r _  # the newline --batch writes after the contents
        LINK_TARGETS[i]="$target"
        ;;
    esac
    i=$((i + 1))
  done < <(printf '%s\n' "${LINK_SHAS[@]}" | git cat-file --batch)
fi

for i in "${!LINK_PATHS[@]}"; do
  link="${LINK_PATHS[$i]}"
  target="${LINK_TARGETS[$i]}"
  if [ -z "$target" ]; then
    [ "${LINK_STAGED[$i]}" = 1 ] && fail "broken symlink: '${link}' has an empty target."
    continue
  fi
  if ! resolve_in_repo "$link" "$target"; then
    continue  # absolute, or climbing above the root: outside the index's remit
  fi
  # An already-committed link is judged only when this commit removes its target.
  if [ "${LINK_STAGED[$i]}" != 1 ] && [ -z "${REMOVED[$RESOLVED]:-}" ]; then
    continue
  fi
  # ponytail: one `git ls-files` per judged link. Symlink counts in source repos
  # are single digits, and only links this commit touches get here. Build the
  # index path set once, in the pass above, if a repo ever brings thousands.
  # No `-z`: only emptiness is read, and a NUL in a command substitution is
  # dropped with a warning on every match.
  if [ -z "$(git ls-files -- ":(literal)${RESOLVED}")" ]; then
    # ...but an empty answer is not proof of a broken link when the path runs
    # THROUGH another symlink. Git cannot hold an index entry below a symlink
    # path, so for `config-link -> current/config` with `current -> versions/v1`
    # the index holds `current` (120000) and `versions/v1/config`, and nothing at
    # `current/config` — while the checkout resolves it perfectly. Refusing there
    # is a false block, and this file argues at length that a gate people have to
    # switch off is worse than the defect it screens for.
    #
    # This exemption does NOT let a broken chain through, because the ancestor is
    # itself a symlink and gets judged on its own terms. Measured: with
    # `current -> nonexistent` and `config-link -> current/config` both staged,
    # the commit is still refused — on `current`, whose target is untracked. The
    # only gap is an ancestor committed broken EARLIER and not touched now, and
    # that is the pre-existing-link limit this file already documents and takes
    # deliberately, not a hole this escape opens.
    #
    # ponytail: DECLINE to judge rather than resolve the chain. One index lookup
    # per ancestor, no cycle bound needed because nothing is followed. Ceiling: a
    # genuinely broken link reached through a symlinked directory is not caught —
    # the same "outside this check's remit" the absolute and root-escaping cases
    # already take, and the safe direction for a global pre-commit hook. Upgrade
    # path: resolve tracked 120000 components against the index, with a depth
    # bound, when a repo actually needs that caught.
    # The path must match EXACTLY. A pathspec naming a directory matches every
    # entry beneath it, so `ls-files -s -- ':(literal)dir'` happily returns
    # `120000 … dir/inner-link` and reading its mode would declare `dir` a symlink
    # — exempting a genuinely broken `dir/missing` because some unrelated link
    # lives in the same directory. Compare the returned pathname, not just the
    # mode. `-z` because a path may contain a newline.
    via_link=""
    anc="${RESOLVED%/*}"
    while [ -n "$anc" ] && [ "$anc" != "$RESOLVED" ]; do
      while IFS= read -r -d '' entry; do
        [ "${entry#*$'\t'}" = "$anc" ] || continue
        [ "${entry:0:6}" = "120000" ] && via_link="$anc"
        break
      done < <(git ls-files -s -z -- ":(literal)${anc}")
      [ -n "$via_link" ] && break
      [ "$anc" = "${anc%/*}" ] && break
      anc="${anc%/*}"
    done
    if [ -z "$via_link" ]; then
      fail "broken symlink: '${link}' -> '${target}' has no target in the commit ('${RESOLVED}' is not tracked)." \
           "  Stage the target too, or remove the link."
    fi
  fi
done

if [ "$FOUND" != 0 ]; then
  echo "[staged-integrity] BLOCKED — the staged index is what would be committed, and it is malformed." >&2
  echo "[staged-integrity] Nothing has been reviewed yet. Fix the above and re-stage." >&2
  exit 1
fi
