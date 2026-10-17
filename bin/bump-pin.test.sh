#!/usr/bin/env bash
# What: tests for bump-pin.sh — the consumer-repo re-stamp PR opener.
# Where: quality-kit/bin.
# Why:  the drift checker (#deploy-drift task 3) branches its own exit code on
#       this script's, so every contract outcome (usage, already current, PR
#       already open, opened one) has to be provably right off GitHub. `gh`
#       and git's two remote-touching subcommands (ls-remote, clone) are
#       PATH-stubbed; every other git call (checkout/add/commit/push) runs
#       for real against local fixture repos, so the actual commit-and-push
#       mechanics get exercised, not just asserted about.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
BP="$DIR/bump-pin.sh"
KITROOT="$(cd "$DIR/.." && pwd)"
REAL_GIT="$(command -v git)"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }

WORKROOT="$(mktemp -d)"
cleanup_all() { rm -r "$WORKROOT"; }
trap cleanup_all EXIT

# --- fixture: a "kit" checkout with a tagged bin/stamp.sh -------------------
# The fake stamp.sh records its own argv (so the happy-path case can assert
# it was called with the resolved profile) and touches one file, so there is
# always something real for bump-pin.sh to commit — it never has to run the
# real stamp.sh, which has its own dedicated tests.
KIT_FIXTURE="$WORKROOT/kitsrc"
mkdir -p "$KIT_FIXTURE/bin"
cat > "$KIT_FIXTURE/bin/stamp.sh" <<'STAMP'
#!/usr/bin/env bash
echo "STAMP_ARGV: $0 $*" >> "$STUB_LOG"
[ "$3" = "${STAMP_FAIL:-}" ] && { echo "stamp: refused profile $3" >&2; exit 1; }
echo "stamped profile=$3" > "$1/.stamp-marker"
STAMP
chmod +x "$KIT_FIXTURE/bin/stamp.sh"
echo 9.9.9 > "$KIT_FIXTURE/VERSION"
# bump-pin.sh runs from inside the fixture, so its `$KIT` is a real git repo
# with an origin — whatever state this checkout's own .git is in (a worktree's
# .git points at admin state outside the worktree, which may not be present).
cp "$BP" "$KIT_FIXTURE/bin/bump-pin.sh"
# The real counter, not a fake: burn-down seeding must count and normalise rule
# names exactly as the consumer's ratchet will.
cp "$DIR/baseline-rules.sh" "$KIT_FIXTURE/bin/baseline-rules.sh"
# Real too: the seed step installs the consumer's deps with the manager it detects.
cp "$DIR/detect-manager.sh" "$KIT_FIXTURE/bin/detect-manager.sh"
(cd "$KIT_FIXTURE" && "$REAL_GIT" init -q -b main \
  && "$REAL_GIT" config core.hooksPath /dev/null \
  && "$REAL_GIT" add -A \
  && "$REAL_GIT" -c user.name=t -c user.email=t@t commit -q -m init \
  && "$REAL_GIT" tag quality-kit-v9.9.9)
"$REAL_GIT" -C "$KIT_FIXTURE" remote add origin "$KIT_FIXTURE"
BP="$KIT_FIXTURE/bin/bump-pin.sh"
KIT_TAG_SHA="$("$REAL_GIT" -C "$KIT_FIXTURE" rev-parse quality-kit-v9.9.9)"

# A kit whose quality-kit-v9.9.9 tag sits on a commit whose VERSION says
# otherwise: a py-pin consumer would refuse that checkout, so no PR may pin it.
KIT_BADVER="$WORKROOT/kitsrc-badver"
"$REAL_GIT" clone -q "$KIT_FIXTURE" "$KIT_BADVER"
echo 9.9.7 > "$KIT_BADVER/VERSION"
(cd "$KIT_BADVER" && "$REAL_GIT" config core.hooksPath /dev/null \
  && "$REAL_GIT" -c user.name=t -c user.email=t@t commit -qam "wrong VERSION" \
  && "$REAL_GIT" tag -f quality-kit-v9.9.9 >/dev/null)

# --- fixture: a plain repo `gh repo clone` clones from (fresh bare per case) -
# src/pin.py is a py-pin consumer's pin; src/nopin.py lacks the SHA line.
CONSUMER_SRC="$WORKROOT/consumer-src"
mkdir -p "$CONSUMER_SRC/src"
OLD_SHA=1111111111111111111111111111111111111111
printf 'QUALITY_KIT = "/kit"\nQUALITY_KIT_SHA = "%s"\nQUALITY_KIT_VERSION = "9.9.8"\n' \
  "$OLD_SHA" > "$CONSUMER_SRC/src/pin.py"
printf 'QUALITY_KIT_VERSION = "9.9.8"\n' > "$CONSUMER_SRC/src/nopin.py"
# src/link.py is a committed symlink out of the clone: the rewrite must refuse it.
OUTSIDE="$WORKROOT/outside.py"
cp "$CONSUMER_SRC/src/pin.py" "$OUTSIDE"
ln -s "$OUTSIDE" "$CONSUMER_SRC/src/link.py"
(cd "$CONSUMER_SRC" && "$REAL_GIT" init -q -b main \
  && "$REAL_GIT" config core.hooksPath /dev/null \
  && echo hi > README.md && "$REAL_GIT" add -A \
  && "$REAL_GIT" -c user.name=t -c user.email=t@t commit -q -m init)

# --- PATH stubs for gh, and git's ls-remote/clone -----------------------------
# Every other git subcommand (`git -C <dir> <sub>`, or the py-pin probe's
# `git init`) falls through to the real binary below, since `$1` there is
# not one of the two cases this intercepts.
STUBBIN="$WORKROOT/stubbin"
mkdir -p "$STUBBIN"

cat > "$STUBBIN/git" <<EOF
#!/usr/bin/env bash
REAL_GIT="$REAL_GIT"
# bump-pin.sh's very first git call resolves ITS OWN checkout's origin remote
# ("\$KIT" inside bump-pin.sh, always this test's real repo root) to build the
# clone URL used later. That checkout is not guaranteed to carry a real origin
# remote (e.g. under a validation sandbox that snapshots content without the
# linked worktree's git metadata), so it is stubbed here rather than left to
# fall through to the real git, which would make this suite's outcome depend
# on ambient repo state it does not control.
if [ "\$1" = "-C" ] && [ "\$2" = "$KITROOT" ] && [ "\$3" = "remote" ] && [ "\$4" = "get-url" ] && [ "\$5" = "origin" ]; then
  echo "https://example.invalid/quality-kit.git"
  exit 0
fi
case "\$1" in
  ls-remote)
    printf '1111111111111111111111111111111111111111\trefs/tags/quality-kit-v9.9.8\n'
    printf '2222222222222222222222222222222222222222\trefs/tags/quality-kit-v9.9.9\n'
    printf '2222222222222222222222222222222222222222\trefs/tags/quality-kit-v9.9.9^{}\n'
    ;;
  clone)
    echo "git \$*" >> "\$STUB_LOG"
    args=("\$@"); dest="\${args[-1]}"; branch=""
    for i in "\${!args[@]}"; do [ "\${args[\$i]}" = "--branch" ] && branch="\${args[\$((i+1))]}"; done
    exec "\$REAL_GIT" clone --quiet --branch "\$branch" "\$KIT_SRC_DIR" "\$dest"
    ;;
  *)
    exec "\$REAL_GIT" "\$@"
    ;;
esac
EOF
chmod +x "$STUBBIN/git"

cat > "$STUBBIN/gh" <<EOF
#!/usr/bin/env bash
REAL_GIT="$REAL_GIT"
case "\$1" in
  api)
    case "\$2" in
      */contents/.quality-kit.json) printf '%s' "\$PIN_B64" ;;
      */contents/src/*) printf '%s' "\$PY_B64" ;;
      */branches/*) [ "\${BRANCH_EXISTS:-0}" = 1 ] && exit 0 || exit 1 ;;
      *) echo "gh api: unhandled \$2" >&2; exit 1 ;;
    esac
    ;;
  pr)
    case "\$2" in
      list) echo "\${OPEN_PRS:-0}" ;;
      create) echo "gh \$*" >> "\$STUB_LOG"; echo "https://example.invalid/pull/1" ;;
      *) echo "gh pr: unhandled \$2" >&2; exit 1 ;;
    esac
    ;;
  repo)
    case "\$2" in
      clone)
        echo "gh \$*" >> "\$STUB_LOG"
        dest="\$4"
        "\$REAL_GIT" clone --quiet "\$CONSUMER_SRC_BARE" "\$dest"
        # An isolated global config (the burn-down cases) carries the hooks
        # the clone must run; a local /dev/null would override them.
        [ -n "\${GIT_CONFIG_GLOBAL:-}" ] || "\$REAL_GIT" -C "\$dest" config core.hooksPath /dev/null
        ;;
      *) echo "gh repo: unhandled \$2" >&2; exit 1 ;;
    esac
    ;;
  *) echo "gh: unhandled \$1" >&2; exit 1 ;;
esac
EOF
chmod +x "$STUBBIN/gh"

# npm: `ci` logs itself and, given a lockfile, "installs" the oxlint stand-in
# from $NPM_CI_OXLINT (refusing without one, as real npm ci does); every other
# subcommand is the real npm, so lint scripts still run through it.
REAL_NPM="$(command -v npm)"
cat > "$STUBBIN/npm" <<EOF
#!/usr/bin/env bash
if [ "\$1" = ci ]; then
  echo "npm \$*" >> "\$STUB_LOG"
  [ -f package-lock.json ] && [ -n "\${NPM_CI_OXLINT:-}" ] || exit 1
  mkdir -p node_modules/.bin && cp "\$NPM_CI_OXLINT" node_modules/.bin/oxlint
  exit 0
fi
exec "$REAL_NPM" "\$@"
EOF
chmod +x "$STUBBIN/npm"

# CASE_OUT / CASE_RC / CASE_LOG / CASE_CONSUMER_BARE are set by run_case.
CASE_OUT="" CASE_RC=0 CASE_LOG="" CASE_CONSUMER_BARE=""
# Any further args go to bump-pin.sh before the consumer (e.g. --py-pin src/pin.py).
# CASE_KIT picks the kit fixture the stubbed clone serves; STAMP_FAIL (exported
# by the caller) names a profile the fake stamp.sh refuses. CASE_SRC picks the
# consumer repo the clone serves, and CASE_PIN_JSON the .quality-kit.json the
# contents API serves (default: just the version and profile args).
run_case() { # pin_version pin_profile open_prs branch_exists [bump-pin args...]
  local pin_version="$1" pin_profile="$2" open_prs="$3" branch_exists="$4"
  shift 4
  # Under $WORKROOT, not the system temp root: cleanup_all's `rm -r
  # "$WORKROOT"` then reaps every case's log and bare repo too, instead of
  # leaking one mktemp -d per run_case call.
  CASE_LOG="$(mktemp "$WORKROOT/case-XXXXXX.log")"
  CASE_CONSUMER_BARE="$(mktemp -d "$WORKROOT/case-XXXXXX")/consumer.git"
  "$REAL_GIT" clone -q --bare "${CASE_SRC:-$CONSUMER_SRC}" "$CASE_CONSUMER_BARE"
  "$REAL_GIT" -C "$CASE_CONSUMER_BARE" config core.hooksPath /dev/null
  local pin_b64
  pin_b64="$(printf '%s' "${CASE_PIN_JSON:-$(printf '{"version":"%s","profile":"%s"}' "$pin_version" "$pin_profile")}" | base64)"
  local py_b64
  py_b64="$(printf 'QUALITY_KIT_SHA = "%s"\nQUALITY_KIT_VERSION = "%s"\n' "$OLD_SHA" "$pin_version" | base64)"
  CASE_RC=0
  # KIT_REMOTE is set explicitly here rather than left to bump-pin.sh's own
  # fallback (`git -C "$KIT" remote get-url origin`): that fallback reads
  # THIS checkout's own 'origin', which this suite must not depend on — it
  # is not guaranteed to be configured in every environment these tests run
  # in (e.g. an offline validation checkout with no remote at all). The
  # value itself is inert: ls-remote and clone are both PATH-stubbed above
  # and ignore it, materializing tags/content from KIT_SRC_DIR instead.
  CASE_OUT="$(env PATH="$STUBBIN:$PATH" \
    STUB_LOG="$CASE_LOG" KIT_SRC_DIR="${CASE_KIT:-$KIT_FIXTURE}" CONSUMER_SRC_BARE="$CASE_CONSUMER_BARE" \
    KIT_REMOTE="$KIT_FIXTURE" \
    PIN_B64="$pin_b64" PY_B64="$py_b64" OPEN_PRS="$open_prs" BRANCH_EXISTS="$branch_exists" \
    bash "$BP" "$@" example/consumer 2>&1)" || CASE_RC=$?
}
# The bump branch's copy of a consumer file, or empty if the branch never landed.
bumped() { "$REAL_GIT" -C "$CASE_CONSUMER_BARE" show "refs/heads/quality-kit/bump-9.9.9:$1" 2>/dev/null || true; }

# --- 64: usage, no args ------------------------------------------------------
rc=0; out="$(bash "$BP" 2>&1)" || rc=$?
[ "$rc" = 64 ] && ok "no args -> 64" || bad "no args -> 64" "rc=$rc out=$out"

# --- 3: pin already equals the latest tag ------------------------------------
run_case 9.9.9 node 0 0
[ "$CASE_RC" = 3 ] && ok "current pin exits 3" || bad "current pin exits 3" "rc=$CASE_RC out=$CASE_OUT"
[ -s "$CASE_LOG" ] && bad "current pin does no clone" "log: $(cat "$CASE_LOG")" || ok "current pin does no clone"

# --- 3: pin already AHEAD of the resolved latest (never downgrade) ----------
run_case 9.9.10 node 0 0
[ "$CASE_RC" = 3 ] && ok "ahead-of-latest pin exits 3" || bad "ahead-of-latest pin exits 3" "rc=$CASE_RC out=$CASE_OUT"
[ -s "$CASE_LOG" ] && bad "ahead-of-latest pin does no clone" "log: $(cat "$CASE_LOG")" || ok "ahead-of-latest pin does no clone"

# --- 0, no clone: an open bump PR already exists -----------------------------
run_case 9.9.8 node 1 0
[ "$CASE_RC" = 0 ] && ok "open PR exits 0" || bad "open PR exits 0" "rc=$CASE_RC out=$CASE_OUT"
# Mutation target: skip the open-PR check in bump-pin.sh (always fall through
# to the clone) and this goes red — the log picks up a `gh repo clone` line
# even though OPEN_PRS=1 said not to touch anything.
[ -s "$CASE_LOG" ] && bad "open PR does no clone" "log: $(cat "$CASE_LOG")" || ok "open PR does no clone"

# --- non-zero: branch exists with no open PR — never touched ----------------
run_case 9.9.8 node 0 1
[ "$CASE_RC" = 1 ] && ok "orphaned branch refuses" || bad "orphaned branch refuses" "rc=$CASE_RC out=$CASE_OUT"
[ -s "$CASE_LOG" ] && bad "orphaned branch does no clone" "log: $(cat "$CASE_LOG")" || ok "orphaned branch does no clone"

# --- 0: happy path — clone, stamp, commit, push, open a PR -------------------
run_case 9.9.8 node 0 0
[ "$CASE_RC" = 0 ] && ok "happy path exits 0" || bad "happy path exits 0" "rc=$CASE_RC out=$CASE_OUT"
grep -q "^gh repo clone example/consumer" "$CASE_LOG" \
  && ok "happy path cloned the consumer" || bad "happy path cloned the consumer" "log: $(cat "$CASE_LOG")"
grep -q "^git clone.*--branch quality-kit-v9.9.9" "$CASE_LOG" \
  && ok "happy path cloned the kit at the resolved tag" || bad "happy path cloned the kit at the resolved tag" "log: $(cat "$CASE_LOG")"
grep -qE "^STAMP_ARGV: .*bin/stamp\.sh .* --profile node$" "$CASE_LOG" \
  && ok "happy path argv shows stamp.sh with the resolved profile" || bad "happy path argv shows stamp.sh with the resolved profile" "log: $(cat "$CASE_LOG")"
grep -q "^gh pr create" "$CASE_LOG" \
  && ok "happy path opened a PR" || bad "happy path opened a PR" "log: $(cat "$CASE_LOG")"
pr_create_line="$(grep "^gh pr create" "$CASE_LOG" || true)"
# Mutation target: drop --draft from bump-pin.sh's PR-open call and this
# goes red — a ready bump PR is squash-merged unreviewed by a merge sweep.
echo "$pr_create_line" | grep -q -- " --draft" \
  && ok "PR opened as a draft" || bad "PR opened as a draft" "$pr_create_line"
echo "$pr_create_line" | grep -q "9\.9\.8" && echo "$pr_create_line" | grep -q "9\.9\.9" \
  && ok "PR body names both versions" || bad "PR body names both versions" "$pr_create_line"
"$REAL_GIT" -C "$CASE_CONSUMER_BARE" show-ref --verify --quiet refs/heads/quality-kit/bump-9.9.9 \
  && ok "the bump branch actually landed on the remote" || bad "the bump branch actually landed on the remote" "not found"

# === --py-pin: QUALITY_KIT_SHA / QUALITY_KIT_VERSION constants in source =====

# --- 64: a malformed py-pin invocation ---------------------------------------
for args in "--py-pin" "--py-pin ../x.py example/consumer" "--py-pin /etc/x.py example/consumer" \
            "--py-pin src/pin.py" "example/consumer extra"; do
  rc=0; out="$(bash "$BP" $args 2>&1)" || rc=$?
  [ "$rc" = 64 ] && ok "usage '$args' -> 64" || bad "usage '$args' -> 64" "rc=$rc out=$out"
done

# --- 3: QUALITY_KIT_VERSION already at the latest tag ------------------------
run_case 9.9.9 "" 0 0 --py-pin src/pin.py
[ "$CASE_RC" = 3 ] && ok "py-pin: current pin exits 3" || bad "py-pin: current pin exits 3" "rc=$CASE_RC out=$CASE_OUT"
[ -s "$CASE_LOG" ] && bad "py-pin: current pin does no clone" "log: $(cat "$CASE_LOG")" || ok "py-pin: current pin does no clone"

# --- 0: happy path — prove the kit stamps, rewrite both constants, draft PR --
run_case 9.9.8 "" 0 0 --py-pin src/pin.py
[ "$CASE_RC" = 0 ] && ok "py-pin: happy path exits 0" || bad "py-pin: happy path exits 0" "rc=$CASE_RC out=$CASE_OUT"
# py-pin never stamps the consumer, so there is no re-stamp to seed for.
grep -q "not seeding burn-down" <<<"$CASE_OUT" \
  && bad "py-pin bump does not seed" "$CASE_OUT" || ok "py-pin bump does not seed"
pin_after="$(bumped src/pin.py)"
# Mutation target: rewrite only one constant and one of these goes red.
grep -qx "QUALITY_KIT_SHA = \"$KIT_TAG_SHA\"" <<<"$pin_after" \
  && ok "py-pin: SHA rewritten to the tag's commit" || bad "py-pin: SHA rewritten to the tag's commit" "$pin_after"
grep -qx 'QUALITY_KIT_VERSION = "9.9.9"' <<<"$pin_after" \
  && ok "py-pin: VERSION rewritten to the tag's version" || bad "py-pin: VERSION rewritten to the tag's version" "$pin_after"
grep -qx 'QUALITY_KIT = "/kit"' <<<"$pin_after" \
  && ok "py-pin: other lines untouched" || bad "py-pin: other lines untouched" "$pin_after"
# Mutation target: drop the stamp probe loop and this goes red.
for profile in nextjs vite node python; do
  grep -qE "^STAMP_ARGV: .*/stamp-$profile --profile $profile$" "$CASE_LOG" \
    && ok "py-pin: real-kit stamp probe ran for $profile" || bad "py-pin: real-kit stamp probe ran for $profile" "log: $(cat "$CASE_LOG")"
done
[ -z "$(bumped .stamp-marker)" ] \
  && ok "py-pin: the consumer itself is not stamped" || bad "py-pin: the consumer itself is not stamped" "marker present"
pr_create_line="$(grep "^gh pr create" "$CASE_LOG" || true)"
echo "$pr_create_line" | grep -q -- " --draft" \
  && ok "py-pin: PR opened as a draft" || bad "py-pin: PR opened as a draft" "$pr_create_line"
echo "$pr_create_line" | grep -q "$KIT_TAG_SHA" \
  && ok "py-pin: PR body names the pinned sha" || bad "py-pin: PR body names the pinned sha" "$pr_create_line"

# --- refused: the tag's VERSION disagrees with the tag -----------------------
# Mutation target: drop the VERSION check and this pins a checkout the
# consumer would refuse to run.
CASE_KIT="$KIT_BADVER" run_case 9.9.8 "" 0 0 --py-pin src/pin.py
[ "$CASE_RC" = 1 ] && ok "py-pin: tag/VERSION mismatch refuses" || bad "py-pin: tag/VERSION mismatch refuses" "rc=$CASE_RC out=$CASE_OUT"
grep -q "VERSION reads 9.9.7" <<<"$CASE_OUT" \
  && ok "py-pin: mismatch names the VERSION it read" || bad "py-pin: mismatch names the VERSION it read" "$CASE_OUT"
grep -q "^gh " "$CASE_LOG" && bad "py-pin: mismatch clones and opens nothing" "log: $(cat "$CASE_LOG")" \
  || ok "py-pin: mismatch clones and opens nothing"

# --- refused: the real kit at the tag fails to stamp a profile ---------------
export STAMP_FAIL=vite
run_case 9.9.8 "" 0 0 --py-pin src/pin.py
unset STAMP_FAIL
[ "$CASE_RC" = 1 ] && ok "py-pin: stamp failure refuses" || bad "py-pin: stamp failure refuses" "rc=$CASE_RC out=$CASE_OUT"
grep -q "fails to stamp profile vite" <<<"$CASE_OUT" \
  && ok "py-pin: stamp failure names the profile" || bad "py-pin: stamp failure names the profile" "$CASE_OUT"
grep -q "^gh " "$CASE_LOG" && bad "py-pin: stamp failure clones and opens nothing" "log: $(cat "$CASE_LOG")" \
  || ok "py-pin: stamp failure clones and opens nothing"

# --- refused: the file lacks one of the two constants ------------------------
run_case 9.9.8 "" 0 0 --py-pin src/nopin.py
[ "$CASE_RC" != 0 ] && ok "py-pin: missing SHA line refuses" || bad "py-pin: missing SHA line refuses" "rc=$CASE_RC out=$CASE_OUT"
grep -q "^gh pr create" "$CASE_LOG" && bad "py-pin: missing SHA line opens no PR" "log: $(cat "$CASE_LOG")" \
  || ok "py-pin: missing SHA line opens no PR"
"$REAL_GIT" -C "$CASE_CONSUMER_BARE" show-ref --verify --quiet refs/heads/quality-kit/bump-9.9.9 \
  && bad "py-pin: missing SHA line pushes no branch" "branch landed" || ok "py-pin: missing SHA line pushes no branch"

# --- refused: the pin path is a symlink out of the consumer clone ------------
# Mutation target: drop the realpath check and the host file gets rewritten.
run_case 9.9.8 "" 0 0 --py-pin src/link.py
[ "$CASE_RC" != 0 ] && ok "py-pin: symlinked pin path refuses" || bad "py-pin: symlinked pin path refuses" "rc=$CASE_RC out=$CASE_OUT"
cmp -s "$OUTSIDE" "$CONSUMER_SRC/src/pin.py" \
  && ok "py-pin: symlink target outside the clone untouched" || bad "py-pin: symlink target outside the clone untouched" "$(cat "$OUTSIDE")"
grep -q "^gh pr create" "$CASE_LOG" && bad "py-pin: symlinked pin path opens no PR" "log: $(cat "$CASE_LOG")" \
  || ok "py-pin: symlinked pin path opens no PR"

# === default mode: seed blocking pre-existing lint findings (#98) ============
# booking-platform's bump was refused by its own pre-commit hook: its ledger was
# already non-empty, so the re-stamp never seeded the kit's new quality-kit/*
# rules and their pre-existing hits stayed at `error`. This consumer has such a
# ledger, a lint script, and an oxlint stand-in driven by LINT_SPEC: one
# "<code> <burnDown key> <n> <severity> <n once ledgered> <severity once
# ledgered>" entry per rule, ';'-separated, read against the CURRENT ledger —
# which is what the kit's nextjs config does (a burnDown key lints at warn).
QK_JSON='{"version":"9.9.8","profile":"nextjs","runner":"npm","pendingFlags":[],"ruleOverrides":{"burnDown":{"no-console":3},"permanent":{}},"ignoreOverrides":[]}'
QK_NOLINT_SRC="$WORKROOT/consumer-qk-nolint-src"
QK_SRC="$WORKROOT/consumer-qk-src"
mkdir -p "$QK_NOLINT_SRC"
printf '%s\n' "$QK_JSON" > "$QK_NOLINT_SRC/.quality-kit.json"
printf '{"name":"consumer","private":true,"scripts":{"lint":"oxlint --type-aware"}}\n' > "$QK_NOLINT_SRC/package.json"
cp -r "$QK_NOLINT_SRC" "$QK_SRC"
mkdir -p "$QK_SRC/node_modules/.bin"
cat > "$QK_SRC/node_modules/.bin/oxlint" <<'OXLINT'
#!/usr/bin/env python3
import json, os
burn = json.load(open(".quality-kit.json"))["ruleOverrides"]["burnDown"]
diags = []
for spec in os.environ["LINT_SPEC"].split(";"):
    code, key, n, sev, ledgered_n, ledgered_sev = spec.split()
    if key in burn:
        n, sev = ledgered_n, ledgered_sev
    diags += [{"code": code, "severity": sev}] * int(n)
print(json.dumps({"diagnostics": diags}, separators=(",", ":")))
OXLINT
chmod +x "$QK_SRC/node_modules/.bin/oxlint"
for src in "$QK_SRC" "$QK_NOLINT_SRC"; do
  (cd "$src" && "$REAL_GIT" init -q -b main && "$REAL_GIT" config core.hooksPath /dev/null \
    && "$REAL_GIT" add -A && "$REAL_GIT" -c user.name=t -c user.email=t@t commit -q -m init)
done
# Isolated git config, one per hooks directory: "blocking" stands in for the
# consumer's validate:fast lint step, "empty" runs no hook at all.
HOOKS_BLOCKING="$WORKROOT/hooks-blocking" HOOKS_EMPTY="$WORKROOT/hooks-empty"
mkdir -p "$HOOKS_BLOCKING" "$HOOKS_EMPTY"
cat > "$HOOKS_BLOCKING/pre-commit" <<'HOOK'
#!/usr/bin/env bash
npm run --silent lint -- --format=json | python3 -c '
import json, sys
if any(d["severity"] == "error" for d in json.load(sys.stdin)["diagnostics"]):
    sys.exit("[quality-kit] BLOCKED: lint reports error-severity findings")'
HOOK
chmod +x "$HOOKS_BLOCKING/pre-commit"
for h in "$HOOKS_BLOCKING" "$HOOKS_EMPTY"; do printf '[core]\n\thooksPath = %s\n' "$h" > "$h.gitconfig"; done
run_qk_case() { # hooks_dir consumer_src lint_spec
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$1.gitconfig" LINT_SPEC="$3"
  CASE_SRC="$2" CASE_PIN_JSON="$QK_JSON" run_case 9.9.8 nextjs 0 0
  unset GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL LINT_SPEC
}
# The pushed bump commit's burnDown, keys sorted, or empty if nothing landed.
pushed_burn() { bumped .quality-kit.json | python3 -c '
import json, sys
print(json.dumps(json.load(sys.stdin)["ruleOverrides"]["burnDown"], sort_keys=True))' 2>/dev/null || true; }
pr_draft_opened() { grep -q -- "^gh pr create --draft .*--head quality-kit/bump-9.9.9" "$CASE_LOG"; }

# --- the refused booking-platform bump, reproduced ---------------------------
run_qk_case "$HOOKS_BLOCKING" "$QK_SRC" \
  "quality-kit(async-parallel) quality-kit/async-parallel 58 error 58 warning;eslint(no-console) no-console 2 warning 2 warning;eslint(no-alert) no-alert 4 warning 4 warning"
[ "$CASE_RC" = 0 ] && pr_draft_opened \
  && ok "unbaselined async-parallel errors no longer block the bump commit" \
  || bad "unbaselined async-parallel errors no longer block the bump commit" "rc=$CASE_RC out=$CASE_OUT log: $(cat "$CASE_LOG")"
burn="$(pushed_burn)"
[ "$burn" = '{"no-console": 3, "quality-kit/async-parallel": 58}' ] \
  && ok "the bump commit seeds async-parallel into burnDown" || bad "the bump commit seeds async-parallel into burnDown" "burnDown=$burn"
# This consumer TRACKS node_modules (its oxlint stand-in): no install ran, so
# the bump commit must leave it alone rather than unstage it into a deletion.
[ -n "$(bumped node_modules/.bin/oxlint)" ] \
  && ok "a tracked node_modules survives the bump" || bad "a tracked node_modules survives the bump" "deleted on the bump branch"
# --- existing ledger entries and warning-only rules are left alone ----------
python3 -c 'import json,sys; sys.exit(0 if json.loads(sys.argv[1])["no-console"] == 3 else 1)' "$burn" 2>/dev/null \
  && ok "an existing ledger entry keeps its count" || bad "an existing ledger entry keeps its count" "burnDown=$burn"
python3 -c 'import json,sys; sys.exit(1 if "no-alert" in json.loads(sys.argv[1]) else 0)' "$burn" 2>/dev/null \
  && ok "a warning-only rule is not seeded" || bad "a warning-only rule is not seeded" "burnDown=$burn"

# --- seeded counts are the recount taken with the rule already ledgered ------
run_qk_case "$HOOKS_EMPTY" "$QK_SRC" \
  "quality-kit(async-parallel) quality-kit/async-parallel 58 error 57 warning;quality-kit(js-flatmap-filter) quality-kit/js-flatmap-filter 2 error 0 warning"
[ "$CASE_RC" = 0 ] && pr_draft_opened \
  && ok "recount case opens the draft PR" || bad "recount case opens the draft PR" "rc=$CASE_RC out=$CASE_OUT"
burn="$(pushed_burn)"
[ "$burn" = '{"no-console": 3, "quality-kit/async-parallel": 57}' ] \
  && ok "seeded counts are the ledgered recount, zero-count rules dropped" \
  || bad "seeded counts are the ledgered recount, zero-count rules dropped" "burnDown=$burn"

# --- nothing new to seed leaves the ledger unchanged -------------------------
run_qk_case "$HOOKS_BLOCKING" "$QK_SRC" "eslint(no-console) no-console 2 warning 2 warning"
[ "$CASE_RC" = 0 ] && pr_draft_opened \
  && ok "nothing to seed still opens the draft PR" || bad "nothing to seed still opens the draft PR" "rc=$CASE_RC out=$CASE_OUT"
burn="$(pushed_burn)"
[ "$burn" = '{"no-console": 3}' ] \
  && ok "nothing to seed leaves the ledger unchanged" || bad "nothing to seed leaves the ledger unchanged" "burnDown=$burn"

# --- linter not installed in the clone: report, then bump anyway -------------
run_qk_case "$HOOKS_EMPTY" "$QK_NOLINT_SRC" "eslint(no-console) no-console 2 warning 2 warning"
[ "$CASE_RC" = 0 ] && pr_draft_opened \
  && ok "uncountable findings still open the draft PR" || bad "uncountable findings still open the draft PR" "rc=$CASE_RC out=$CASE_OUT"
grep -qF "bump-pin: not seeding burn-down (baseline-rules.sh exit 3)" <<<"$CASE_OUT" \
  && ok "uncountable findings name baseline-rules.sh's exit" || bad "uncountable findings name baseline-rules.sh's exit" "$CASE_OUT"
burn="$(pushed_burn)"
[ "$burn" = '{"no-console": 3}' ] \
  && ok "uncountable findings leave the ledger unchanged" || bad "uncountable findings leave the ledger unchanged" "burnDown=$burn"

# --- a fresh clone has no node_modules: install, THEN seed --------------------
# The real failure (booking-platform, after #99): `gh repo clone` brings no
# node_modules, baseline-rules.sh exits 3, nothing seeds, and the hook — which
# installs the deps itself — blocks the commit on the 58 errors. This consumer
# has a lockfile and no node_modules; only `npm ci` provides the linter, so a
# seeded ledger proves the install ran first. Twice: gitignoring node_modules
# (booking-platform's shape) and not, where the install must still stay out.
for ignored in 1 0; do
  QK_NODEPS_SRC="$WORKROOT/consumer-qk-nodeps-src-$ignored"
  mkdir -p "$QK_NODEPS_SRC"
  cp "$QK_NOLINT_SRC/.quality-kit.json" "$QK_NOLINT_SRC/package.json" "$QK_NODEPS_SRC/"
  echo '{"lockfileVersion":3}' > "$QK_NODEPS_SRC/package-lock.json"
  [ "$ignored" = 0 ] || echo node_modules > "$QK_NODEPS_SRC/.gitignore"
  (cd "$QK_NODEPS_SRC" && "$REAL_GIT" init -q -b main && "$REAL_GIT" config core.hooksPath /dev/null \
    && "$REAL_GIT" add -A && "$REAL_GIT" -c user.name=t -c user.email=t@t commit -q -m init)
  export NPM_CI_OXLINT="$QK_SRC/node_modules/.bin/oxlint"
  run_qk_case "$HOOKS_BLOCKING" "$QK_NODEPS_SRC" \
    "quality-kit(async-parallel) quality-kit/async-parallel 58 error 58 warning"
  unset NPM_CI_OXLINT
  t="(node_modules gitignored=$ignored)"
  [ "$CASE_RC" = 0 ] && pr_draft_opened \
    && ok "a clone without node_modules installs, seeds, and opens the draft PR $t" \
    || bad "a clone without node_modules installs, seeds, and opens the draft PR $t" "rc=$CASE_RC out=$CASE_OUT log: $(cat "$CASE_LOG")"
  grep -qx "npm ci --ignore-scripts --no-audit --no-fund" "$CASE_LOG" \
    && ok "the seed step ran npm ci without lifecycle scripts $t" || bad "the seed step ran npm ci without lifecycle scripts $t" "log: $(cat "$CASE_LOG")"
  burn="$(pushed_burn)"
  [ "$burn" = '{"no-console": 3, "quality-kit/async-parallel": 58}' ] \
    && ok "the installed linter's errors are seeded $t" || bad "the installed linter's errors are seeded $t" "burnDown=$burn"
  [ -z "$(bumped node_modules/.bin/oxlint)" ] \
    && ok "the install is not committed $t" || bad "the install is not committed $t" "node_modules landed on the bump branch"
done

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
