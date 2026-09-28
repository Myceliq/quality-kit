#!/usr/bin/env bash
# What: decide whether quality-kit-v<VERSION> needs creating, given the tags
#       that already exist on the remote.
# Where: quality-kit/bin; called by .github/workflows/release.yml on every push
#        to main. The workflow does the git/network side (list remote tags,
#        create+push an annotated tag); this script is only the decision, so
#        it's testable off GitHub (bin/release-tag.test.sh) instead of only
#        being provable by watching a real CI run land the wrong thing.
# Why:   v0.5.4 merged to main and was never tagged — a stamped repo's CI
#        resolves quality-kit-v0.5.4 at checkout and breaks. Manual tagging is
#        the root cause; this makes tagging a deterministic function of the
#        VERSION file and the remote's tag list instead of a step a human has
#        to remember to run.
set -euo pipefail
VERSION="${1:?usage: release-tag.sh <version> <existing-tags-file>}"
TAGS_FILE="${2:?usage: release-tag.sh <version> <existing-tags-file>}"

# Strict semver core triplet only — no pre-release/build metadata, no short
# form, no leading zeros (semver.org: numeric identifiers MUST NOT have them,
# so "01.2.3" is as invalid as "1.2"). A fuzzier match would let a malformed
# VERSION resolve to SOME tag string and get pushed anyway.
if ! [[ "$VERSION" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
  echo invalid
  exit 1
fi

TAG="quality-kit-v$VERSION"

# Exact whole-line match: a tags file line that merely CONTAINS $TAG (a longer
# version sharing the prefix, or noise around it) must not read as "already
# tagged" and suppress the real create.
if [ -f "$TAGS_FILE" ] && grep -qxF "$TAG" "$TAGS_FILE"; then
  echo skip
  exit 0
fi

echo create
exit 0
