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
echo "stamped profile=$3" > "$1/.stamp-marker"
STAMP
chmod +x "$KIT_FIXTURE/bin/stamp.sh"
(cd "$KIT_FIXTURE" && "$REAL_GIT" init -q -b main \
  && "$REAL_GIT" config core.hooksPath /dev/null \
  && "$REAL_GIT" add -A \
  && "$REAL_GIT" -c user.name=t -c user.email=t@t commit -q -m init \
  && "$REAL_GIT" tag quality-kit-v9.9.9)

# --- fixture: a plain repo `gh repo clone` clones from (fresh bare per case) -
CONSUMER_SRC="$WORKROOT/consumer-src"
mkdir -p "$CONSUMER_SRC"
(cd "$CONSUMER_SRC" && "$REAL_GIT" init -q -b main \
  && "$REAL_GIT" config core.hooksPath /dev/null \
  && echo hi > README.md && "$REAL_GIT" add -A \
  && "$REAL_GIT" -c user.name=t -c user.email=t@t commit -q -m init)

# --- PATH stubs for gh, and git's ls-remote/clone -----------------------------
# Every other git subcommand (always invoked as `git -C <dir> <sub>` by
# bump-pin.sh) falls through to the real binary below, since `$1` there is
# `-C`, not one of the two cases this intercepts.
STUBBIN="$WORKROOT/stubbin"
mkdir -p "$STUBBIN"

cat > "$STUBBIN/git" <<EOF
#!/usr/bin/env bash
REAL_GIT="$REAL_GIT"
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
        "\$REAL_GIT" -C "\$dest" config core.hooksPath /dev/null
        ;;
      *) echo "gh repo: unhandled \$2" >&2; exit 1 ;;
    esac
    ;;
  *) echo "gh: unhandled \$1" >&2; exit 1 ;;
esac
EOF
chmod +x "$STUBBIN/gh"

# CASE_OUT / CASE_RC / CASE_LOG / CASE_CONSUMER_BARE are set by run_case.
CASE_OUT="" CASE_RC=0 CASE_LOG="" CASE_CONSUMER_BARE=""
run_case() { # pin_version pin_profile open_prs branch_exists
  local pin_version="$1" pin_profile="$2" open_prs="$3" branch_exists="$4"
  # Under $WORKROOT, not the system temp root: cleanup_all's `rm -r
  # "$WORKROOT"` then reaps every case's log and bare repo too, instead of
  # leaking one mktemp -d per run_case call.
  CASE_LOG="$(mktemp "$WORKROOT/case-XXXXXX.log")"
  CASE_CONSUMER_BARE="$(mktemp -d "$WORKROOT/case-XXXXXX")/consumer.git"
  "$REAL_GIT" clone -q --bare "$CONSUMER_SRC" "$CASE_CONSUMER_BARE"
  "$REAL_GIT" -C "$CASE_CONSUMER_BARE" config core.hooksPath /dev/null
  local pin_b64
  pin_b64="$(printf '{"version":"%s","profile":"%s"}' "$pin_version" "$pin_profile" | base64)"
  CASE_RC=0
  CASE_OUT="$(env PATH="$STUBBIN:$PATH" \
    STUB_LOG="$CASE_LOG" KIT_SRC_DIR="$KIT_FIXTURE" CONSUMER_SRC_BARE="$CASE_CONSUMER_BARE" \
    PIN_B64="$pin_b64" OPEN_PRS="$open_prs" BRANCH_EXISTS="$branch_exists" \
    bash "$BP" example/consumer 2>&1)" || CASE_RC=$?
}

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
echo "$pr_create_line" | grep -q "9\.9\.8" && echo "$pr_create_line" | grep -q "9\.9\.9" \
  && ok "PR body names both versions" || bad "PR body names both versions" "$pr_create_line"
"$REAL_GIT" -C "$CASE_CONSUMER_BARE" show-ref --verify --quiet refs/heads/quality-kit/bump-9.9.9 \
  && ok "the bump branch actually landed on the remote" || bad "the bump branch actually landed on the remote" "not found"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
