#!/usr/bin/env bash
# What: open a re-stamp PR in a consumer repo when its pinned kit version is
#       behind the latest quality-kit-v* release.
# Where: quality-kit/bin; called by the drift checker (#deploy-drift task 3)
#        so a kit upgrade doesn't depend on someone remembering to re-stamp
#        every fleet repo by hand.
# Why:   exit codes are a contract the caller branches on: 0 = a bump PR is
#        open (just created, or already there), 3 = the consumer is already
#        current, 64 = usage, anything else = failure. It never force-pushes
#        and never touches a branch it didn't just create, so a caller that
#        calls this on a timer can't clobber someone's in-flight bump.
set -euo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONSUMER="${1:-}"
[[ "$CONSUMER" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] \
  || { echo "usage: bump-pin.sh <owner/repo>" >&2; exit 64; }

# The kit's own remote — resolved from this checkout, never a hardcoded path,
# so the script works from any clone of quality-kit (and a test's fixture).
KIT_REMOTE="$(git -C "$KIT" remote get-url origin)"

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
PIN_JSON="$(gh api "repos/$CONSUMER/contents/.quality-kit.json" --jq '.content' | base64 -d)"
PIN_VERSION="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("version",""))' <<<"$PIN_JSON")"
PIN_PROFILE="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("profile",""))' <<<"$PIN_JSON")"
[ -n "$PIN_VERSION" ] && [ -n "$PIN_PROFILE" ] \
  || { echo "bump-pin: $CONSUMER's .quality-kit.json has no version/profile" >&2; exit 1; }

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

CONSUMER_DIR="$WORK/repo"
gh repo clone "$CONSUMER" "$CONSUMER_DIR"

# The kit at the tag, in its own temp dir — never the operator's checkout,
# never this script's own $KIT (which may be ahead of what was tagged).
git clone --quiet --depth 1 --branch "$LATEST_TAG" "$KIT_REMOTE" "$KITSRC"

bash "$KITSRC/bin/stamp.sh" "$CONSUMER_DIR" --profile "$PIN_PROFILE"

git -C "$CONSUMER_DIR" checkout -q -b "$BRANCH"
git -C "$CONSUMER_DIR" add -A
git -C "$CONSUMER_DIR" \
  -c user.name="quality-kit-bot" -c user.email="quality-kit-bot@users.noreply.github.com" \
  commit -q -m "chore(quality-kit): bump pin $PIN_VERSION -> $LATEST_VERSION"
git -C "$CONSUMER_DIR" push -q -u origin "$BRANCH"

gh pr create --repo "$CONSUMER" --head "$BRANCH" \
  --title "chore(quality-kit): bump pin to $LATEST_VERSION" \
  --body "Bumps the quality-kit pin from $PIN_VERSION to $LATEST_VERSION."
echo "bump-pin: opened PR for $CONSUMER $PIN_VERSION -> $LATEST_VERSION"
