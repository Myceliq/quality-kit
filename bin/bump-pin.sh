#!/usr/bin/env bash
# What: open a pin-bump PR in a consumer repo when its pinned kit version is
#       behind the latest quality-kit-v* release (a re-stamp by default, or a
#       QUALITY_KIT_SHA/QUALITY_KIT_VERSION rewrite with --py-pin).
# Where: quality-kit/bin; called by the drift checker (#deploy-drift task 3)
#        so a kit upgrade doesn't depend on someone remembering to re-stamp
#        every fleet repo by hand.
# Why:   exit codes are a contract the caller branches on: 0 = a bump PR is
#        open (just created, or already there), 3 = the consumer is already
#        current, 64 = usage, anything else = failure. It never force-pushes
#        and never touches a branch it didn't just create, so a caller that
#        calls this on a timer can't clobber someone's in-flight bump.
#
# Two pin shapes. Default: the consumer's .quality-kit.json, re-stamped with
# stamp.sh. `--py-pin <path>`: a consumer that runs the kit itself, pinning it
# in source as QUALITY_KIT_SHA = "<sha>" / QUALITY_KIT_VERSION = "<X.Y.Z>" lines
# in <path>. That consumer is not stamped; both constants are rewritten to the
# tag's commit and VERSION, and only after the real kit at that commit has
# proven it stamps (see "py-pin: prove the pin resolves" below). Either way the
# PR opens as a draft.
set -euo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
usage() { echo "usage: bump-pin.sh [--py-pin <path>] <owner/repo>" >&2; exit 64; }
PY_PIN=""
if [ "${1:-}" = --py-pin ]; then
  [ $# -ge 2 ] || usage
  PY_PIN="$2"; shift 2
  # A repo-relative path only: it goes into an API URL and a path under the
  # clone, so no leading '/', no '..', nothing outside a plain path alphabet.
  [[ "$PY_PIN" =~ ^[A-Za-z0-9_.][A-Za-z0-9_./-]*$ && "$PY_PIN" != *..* ]] || usage
fi
CONSUMER="${1:-}"
[ $# -eq 1 ] && [[ "$CONSUMER" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || usage

# The kit's own remote — resolved from this checkout, never a hardcoded path,
# so the script works from any clone of quality-kit (and a test's fixture).
# KIT_REMOTE is overridable: a caller (this script's own test) can point it at
# a local fixture remote instead of depending on THIS checkout's own 'origin'
# being configured, which is not guaranteed in every environment this runs in
# (e.g. an offline validation checkout with no remote at all).
KIT_REMOTE="${KIT_REMOTE:-$(git -C "$KIT" remote get-url origin)}"

# --- latest quality-kit-v* tag, semver-highest -------------------------------
# `git ls-remote` reads the remote directly (global-constraints: origin, never
# a local branch) so a checkout with stale/unfetched tags can't under-report.
# `sort -V` (coreutils version sort) already handles dotted-decimal ordering
# correctly (0.5.9 < 0.5.10 < 0.9.0), so there's no reason to hand-roll the
# comparison release-tag.sh doesn't do either — that script only validates
# VERSION's shape, it never compares two tags.
LATEST_TAG="$(git ls-remote --tags "$KIT_REMOTE" 2>/dev/null \
  | awk '{print $2}' \
  | sed -n 's#^refs/tags/\(quality-kit-v[0-9][0-9.]*\)$#\1#p' \
  | sort -V | tail -1)"
[ -n "$LATEST_TAG" ] || { echo "bump-pin: no quality-kit-v* tags found at $KIT_REMOTE" >&2; exit 1; }
LATEST_VERSION="${LATEST_TAG#quality-kit-v}"

# --- consumer's current pin, read from its default branch on GitHub ---------
if [ -n "$PY_PIN" ]; then
  PY_SRC="$(gh api "repos/$CONSUMER/contents/$PY_PIN" --jq '.content' | base64 -d)"
  PIN_VERSION="$(python3 -c '
import re, sys
m = re.findall(r"^QUALITY_KIT_VERSION\s*=\s*\"([^\"]*)\"", sys.stdin.read(), re.M)
print(m[0] if len(m) == 1 else "")' <<<"$PY_SRC")"
  [ -n "$PIN_VERSION" ] \
    || { echo "bump-pin: $CONSUMER's $PY_PIN has no single QUALITY_KIT_VERSION line" >&2; exit 1; }
else
  PIN_JSON="$(gh api "repos/$CONSUMER/contents/.quality-kit.json" --jq '.content' | base64 -d)"
  PIN_VERSION="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))' <<<"$PIN_JSON")"
  PIN_PROFILE="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("profile",""))' <<<"$PIN_JSON")"
  [ -n "$PIN_VERSION" ] && [ -n "$PIN_PROFILE" ] \
    || { echo "bump-pin: $CONSUMER's .quality-kit.json has no version/profile" >&2; exit 1; }
fi

# >=, not ==: a pin already AHEAD of what this run resolved as "latest" (a
# tag deleted after the consumer bumped, or a momentarily stale remote) must
# read as current too — an exact-equality check would "bump" that consumer
# backward to an older tag, which is the opposite of this script's job.
HIGHER_VERSION="$(printf '%s\n%s\n' "$PIN_VERSION" "$LATEST_VERSION" | sort -V | tail -1)"
if [ "$HIGHER_VERSION" = "$PIN_VERSION" ]; then
  echo "bump-pin: $CONSUMER is already at $PIN_VERSION (latest resolved: $LATEST_VERSION)"
  exit 3
fi

BRANCH="quality-kit/bump-$LATEST_VERSION"

# An open PR on that branch means the bump is already in flight — done, and
# without cloning anything (the drift checker calls this often; the common
# case after the first run of a given version must be cheap and side-effect
# free).
OPEN_PRS="$(gh pr list --repo "$CONSUMER" --head "$BRANCH" --state open --json number --jq 'length')" \
  || { echo "bump-pin: gh pr list failed for $CONSUMER" >&2; exit 1; }
if [ "$OPEN_PRS" != 0 ]; then
  echo "bump-pin: open PR already exists for $BRANCH on $CONSUMER"
  exit 0
fi

# The branch existing WITHOUT an open PR means someone closed the PR, or is
# mid-push on it by hand — either way it's not this run's to touch. Refuse
# rather than push (which would need --force to win a diverged history, and
# this script never force-pushes).
if gh api "repos/$CONSUMER/branches/$BRANCH" >/dev/null 2>&1; then
  echo "bump-pin: branch $BRANCH exists on $CONSUMER with no open PR — refusing to touch it" >&2
  exit 1
fi

WORK="$(mktemp -d)"
KITSRC="$(mktemp -d)"
cleanup() { rm -r "$WORK" "$KITSRC"; }
trap cleanup EXIT

# The kit at the tag, in its own temp dir — never the operator's checkout,
# never this script's own $KIT (which may be ahead of what was tagged).
git clone --quiet --depth 1 --branch "$LATEST_TAG" "$KIT_REMOTE" "$KITSRC"

# --- py-pin: prove the pin resolves before writing it -------------------------
# A py-pin consumer refuses to run the kit unless its checkout is exactly
# QUALITY_KIT_SHA and its VERSION file reads QUALITY_KIT_VERSION, then runs
# stamp.sh from it. Its own tests use a fake kit, so nothing there proves a
# bumped pin is a real, stampable kit: prove it here, on the real kit at the
# tag, or open nothing. Every profile stamp.sh serves (its usage line), into a
# throwaway repo each.
if [ -n "$PY_PIN" ]; then
  KIT_SHA="$(git -C "$KITSRC" rev-parse HEAD)"
  KIT_VERSION="$(cat "$KITSRC/VERSION")"
  [ "$KIT_VERSION" = "$LATEST_VERSION" ] \
    || { echo "bump-pin: $LATEST_TAG's VERSION reads $KIT_VERSION, not $LATEST_VERSION — not pinning it" >&2; exit 1; }
  for profile in nextjs vite node python; do
    git init -q "$WORK/stamp-$profile"
    bash "$KITSRC/bin/stamp.sh" "$WORK/stamp-$profile" --profile "$profile" >/dev/null \
      || { echo "bump-pin: $LATEST_TAG ($KIT_SHA) fails to stamp profile $profile — not pinning it" >&2; exit 1; }
  done
fi

CONSUMER_DIR="$WORK/repo"
gh repo clone "$CONSUMER" "$CONSUMER_DIR"

if [ -n "$PY_PIN" ]; then
  # Exactly one line per constant, or refuse: a second match is a shape this
  # script does not understand, and rewriting either one could miss the live pin.
  # The consumer's tree is untrusted: a symlinked path (or component) could aim
  # the write at a host file, so the resolved target must stay inside the clone.
  python3 - "$CONSUMER_DIR" "$PY_PIN" "$KIT_SHA" "$LATEST_VERSION" <<'PY'
import os, re, sys
root, rel, sha, version = sys.argv[1:]
root = os.path.realpath(root)
path = os.path.join(root, rel)
if os.path.realpath(path) != path or not os.path.isfile(path):
    sys.exit(f"bump-pin: {rel} is not a regular file inside the consumer (symlink or missing)")
src = open(path, encoding="utf-8").read()
for name, value in (("QUALITY_KIT_SHA", sha), ("QUALITY_KIT_VERSION", version)):
    src, n = re.subn(rf'^({name}\s*=\s*)"[^"]*"', lambda m: f'{m[1]}"{value}"', src, flags=re.M)
    if n != 1:
        sys.exit(f"bump-pin: {path} has {n} {name} lines, need exactly 1")
open(path, "w", encoding="utf-8").write(src)
PY
  BODY="Bumps the quality-kit pin from $PIN_VERSION to $LATEST_VERSION: QUALITY_KIT_SHA $KIT_SHA ($LATEST_TAG). The kit at that commit stamped every profile before this PR opened."
else
  bash "$KITSRC/bin/stamp.sh" "$CONSUMER_DIR" --profile "$PIN_PROFILE"
  BODY="Bumps the quality-kit pin from $PIN_VERSION to $LATEST_VERSION."
fi

git -C "$CONSUMER_DIR" checkout -q -b "$BRANCH"
git -C "$CONSUMER_DIR" add -A
git -C "$CONSUMER_DIR" \
  -c user.name="quality-kit-bot" -c user.email="quality-kit-bot@users.noreply.github.com" \
  commit -q -m "chore(quality-kit): bump pin $PIN_VERSION -> $LATEST_VERSION"
git -C "$CONSUMER_DIR" push -q -u origin "$BRANCH"

# --draft: a consumer's merge sweep may squash-merge any green non-draft PR
# (booking-platform's does), so a ready bump would reach main unreviewed.
# A human marks it ready after reading the bump diff. Both pin shapes.
gh pr create --draft --repo "$CONSUMER" --head "$BRANCH" \
  --title "chore(quality-kit): bump pin to $LATEST_VERSION" \
  --body "$BODY"
echo "bump-pin: opened PR for $CONSUMER $PIN_VERSION -> $LATEST_VERSION"
