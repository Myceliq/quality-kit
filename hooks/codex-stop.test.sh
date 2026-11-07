#!/usr/bin/env bash
# What: tests for hooks/codex-stop.sh, the user-level Codex Stop hook. Where: quality-kit/hooks.
# Why:  the hook's whole job is a decision — run this repository's turn-end script or do not —
#       and a wrong "do not" is silent while a wrong "run" executes a repository's code. Every
#       negative arm here has a positive twin that differs in one thing, so "nothing ran" is
#       never mistaken for "refused".
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$DIR/codex-stop.sh"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }

python3 -I -c 'import tomllib' 2>/dev/null || { echo "FAIL codex-stop needs python3 >= 3.11 (tomllib); none on PATH"; exit 1; }

# `pwd -P`: fixtures live under a physical path, so "the path as spelled" and "the canonical
# path" coincide unless an arm builds an alias on purpose.
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -r "$T"' EXIT
export CODEX_HOME="$T/codex-home"; mkdir -p "$CODEX_HOME"
git() { command git -c user.name=t -c user.email=t@t -c core.hooksPath=/dev/null "$@"; }

# Every fixture repository carries the SAME stand-in for .quality/stop-validate.sh: it records
# that it ran (its own checkout, its cwd and the payload it was handed) in `stop-ran` at its
# checkout root, prints to stderr and exits 2 — the block protocol, so an arm can also tell
# that the status and stderr came through the wrapper untouched.
mk_repo() { # $1=dir → a committed repository with the stand-in gate
  mkdir -p "$1/.quality" "$1/src"
  cat > "$1/.quality/stop-validate.sh" <<'EOF'
#!/usr/bin/env bash
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
{ echo "cwd=$(pwd -P)"; cat; } > "$root/stop-ran"
echo "stand-in gate blocked" >&2
exit 2
EOF
  printf '{"version":"0.0.0","profile":"python","runner":"make"}' > "$1/.quality-kit.json"
  echo 'stop-ran' > "$1/.gitignore"
  (cd "$1" && git init -q && git add -A && git commit -q -m fixture)
}
trust() { # trust <level> <path>...  → REPLACES config.toml; no args after level = no projects
  local level="$1"; shift
  : > "$CODEX_HOME/config.toml"
  local p; for p in "$@"; do printf '[projects."%s"]\ntrust_level = "%s"\n\n' "$p" "$level" >> "$CODEX_HOME/config.toml"; done
}
# stop <payload-cwd> [process-cwd] → rc, err. The process cwd defaults to the payload's, which
# is how Codex launches a hook: in the turn's working directory.
stop() {
  set +e
  err="$( (cd "${2:-$1}" && printf '{"cwd":"%s","stop_hook_active":false,"hook_event_name":"Stop"}' "$1" | bash "$HOOK") 2>&1 >/dev/null )"
  rc=$?
  set -e
}
ran()   { [ -e "$1/stop-ran" ]; }
reset() { rm -f "$@"; }

mk_repo "$T/repo"

# --- the pair: one repository, one payload, and only the trust table differs -------------------
trust trusted
stop "$T/repo"
[ "$rc" = 0 ] && ! ran "$T/repo" \
  && ok "a repository Codex does not trust is not run" \
  || bad "a repository Codex does not trust is not run" "rc=$rc ran=$(ran "$T/repo" && echo yes || echo no)"
trust trusted "$T/repo"
stop "$T/repo"
[ "$rc" = 2 ] && ran "$T/repo" && echo "$err" | grep -q "stand-in gate blocked" \
  && ok "the same repository, trusted, is run and its exit 2 + stderr pass through" \
  || bad "the same repository, trusted, is run and its exit 2 + stderr pass through" "rc=$rc err=$err"
grep -q "^cwd=$T/repo\$" "$T/repo/stop-ran" && grep -q '"stop_hook_active":false' "$T/repo/stop-ran" \
  && ok "the gate runs in the checkout root and receives the payload" \
  || bad "the gate runs in the checkout root and receives the payload" "$(cat "$T/repo/stop-ran")"
reset "$T/repo/stop-ran"

# --- trusting one repository says nothing about another -----------------------------------------
# Same fixture, a second path. The hook is launched from inside it, as Codex would.
mk_repo "$T/other"
stop "$T/other"
[ "$rc" = 0 ] && ! ran "$T/other" && ! ran "$T/repo" \
  && ok "a turn standing in an untrusted repository runs neither it nor the trusted one" \
  || bad "a turn standing in an untrusted repository runs neither it nor the trusted one" "rc=$rc"
stop "$T/repo" "$T/other"
[ "$rc" = 2 ] && ran "$T/repo" && ! ran "$T/other" \
  && ok "the payload's cwd picks the repository, not the hook process's cwd" \
  || bad "the payload's cwd picks the repository, not the hook process's cwd" "rc=$rc"
reset "$T/repo/stop-ran"

# An explicit "untrusted" is a decision, not an absence.
trust untrusted "$T/repo"
stop "$T/repo"
[ "$rc" = 0 ] && ! ran "$T/repo" && ok "trust_level = untrusted is not run" || bad "trust_level = untrusted is not run" "rc=$rc"
trust trusted "$T/repo"

# --- the decision does not load code from the directory being judged ---------------------------
# The untrusted repository carries modules named like the ones the resolver imports. Each writes
# a marker when imported. The control is the same directory with a plain `python3 -c`, which
# does import them — so the arm can fail.
for m in json tomllib os sys; do printf 'open(%s, "w").write("x")\n' "'$T/other/imported-$m'" > "$T/other/$m.py"; done
(cd "$T/other" && python3 -c 'import json, tomllib' >/dev/null 2>&1) || true
ls "$T/other"/imported-* >/dev/null 2>&1 \
  && ok "control: a plain python3 -c in that directory imports its modules" \
  || bad "control: a plain python3 -c in that directory imports its modules" "no marker — the arm below cannot fail"
reset "$T/other"/imported-*
stop "$T/other"
[ "$rc" = 0 ] && ! ls "$T/other"/imported-* >/dev/null 2>&1 && ! ran "$T/other" \
  && ok "the hook imports nothing from the turn's working directory" \
  || bad "the hook imports nothing from the turn's working directory" "rc=$rc $(ls "$T/other")"
reset "$T/other"/*.py

# --- inside a trusted repository ------------------------------------------------------------------
stop "$T/repo/src"
[ "$rc" = 2 ] && grep -q "^cwd=$T/repo\$" "$T/repo/stop-ran" \
  && ok "a subdirectory of a trusted repository runs that repository's gate" \
  || bad "a subdirectory of a trusted repository runs that repository's gate" "rc=$rc"
reset "$T/repo/stop-ran"
# A repository nested inside a trusted one is its own project and needs its own trust; the
# outer gate is not run on its behalf either.
mk_repo "$T/repo/vendor/nested"
stop "$T/repo/vendor/nested"
[ "$rc" = 0 ] && ! ran "$T/repo/vendor/nested" && ! ran "$T/repo" \
  && ok "a repository nested in a trusted one is not covered by it" \
  || bad "a repository nested in a trusted one is not covered by it" "rc=$rc"
# ...while a `.git` directory with no HEAD is not a repository boundary at all.
mkdir -p "$T/repo/src/sub/.git"
stop "$T/repo/src/sub"
[ "$rc" = 2 ] && ran "$T/repo" \
  && ok "an empty .git directory does not hide the enclosing trusted repository" \
  || bad "an empty .git directory does not hide the enclosing trusted repository" "rc=$rc"
reset "$T/repo/stop-ran"; rmdir "$T/repo/src/sub/.git"
# A trusted repository reached through a symlinked path: the canonical key matches.
ln -s "$T/repo" "$T/alias"
stop "$T/alias"
[ "$rc" = 2 ] && ran "$T/repo" \
  && ok "a symlinked path to a trusted repository is trusted" \
  || bad "a symlinked path to a trusted repository is trusted" "rc=$rc"
reset "$T/repo/stop-ran"

# --- linked worktrees -----------------------------------------------------------------------------
(cd "$T/repo" && git worktree add -q --detach "$T/wt")
stop "$T/wt"
[ "$rc" = 2 ] && grep -q "^cwd=$T/wt\$" "$T/wt/stop-ran" && ! ran "$T/repo" \
  && ok "a linked worktree of a trusted repository runs its own gate" \
  || bad "a linked worktree of a trusted repository runs its own gate" "rc=$rc"
reset "$T/wt/stop-ran"
# First match wins: an entry on the worktree's own path outranks its main checkout's.
printf '[projects."%s"]\ntrust_level = "untrusted"\n' "$T/wt" >> "$CODEX_HOME/config.toml"
stop "$T/wt"
[ "$rc" = 0 ] && ! ran "$T/wt" \
  && ok "a worktree marked untrusted is not run although its main checkout is trusted" \
  || bad "a worktree marked untrusted is not run although its main checkout is trusted" "rc=$rc"
trust trusted "$T/repo"

# A directory that only CLAIMS to belong to the trusted repository. Three claims, each the same
# stand-in fixture with a hand-written `.git` file; the worktree arm above is the control that
# shows a genuine registration with this shape of `.git` file does run.
claim() { # $1=dir $2=gitdir target
  mkdir -p "$1/.quality"; cp "$T/repo/.quality/stop-validate.sh" "$1/.quality/"; cp "$T/repo/.quality-kit.json" "$1/"
  printf 'gitdir: %s\n' "$2" > "$1/.git"
}
claim "$T/claim-main" "$T/repo/.git"
stop "$T/claim-main"
[ "$rc" = 0 ] && ! ran "$T/claim-main" \
  && ok "a .git file naming a trusted repository's git dir is not that repository" \
  || bad "a .git file naming a trusted repository's git dir is not that repository" "rc=$rc"
wtname="$(basename "$(cd "$T/wt" && command git rev-parse --git-dir)")"
claim "$T/claim-wt" "$T/repo/.git/worktrees/$wtname"
stop "$T/claim-wt"
[ "$rc" = 0 ] && ! ran "$T/claim-wt" \
  && ok "a .git file naming another checkout's worktree registration is not that worktree" \
  || bad "a .git file naming another checkout's worktree registration is not that worktree" "rc=$rc"
# A lookalike registry of its own: worktrees/x pointing back at the claimant, common dir its own.
mkdir -p "$T/claim-self-git/worktrees/x"
printf '%s\n' "$T/claim-self/.git" > "$T/claim-self-git/worktrees/x/gitdir"
printf '../..\n' > "$T/claim-self-git/worktrees/x/commondir"
claim "$T/claim-self" "$T/claim-self-git/worktrees/x"
stop "$T/claim-self"
[ "$rc" = 0 ] && ! ran "$T/claim-self" \
  && ok "a self-made worktree registry outside any trusted repository is not trusted" \
  || bad "a self-made worktree registry outside any trusted repository is not trusted" "rc=$rc"

# --- the kit's real gate behind the wrapper -------------------------------------------------------
# Not the stand-in: the shipped stop-validate.sh, installed where the stamp puts it, in a trusted
# repository with a dirty tree and a red validate-fast. It must block, which also shows the
# gate's own "is this my project" check accepts being launched this way.
mkdir -p "$T/real/.quality"; cp "$DIR/stop-validate.sh" "$T/real/.quality/"
printf '{"version":"0.0.0","profile":"python","runner":"make"}' > "$T/real/.quality-kit.json"
printf 'validate-fast:\n\t@touch validate-ran; exit 1\n' > "$T/real/Makefile"
(cd "$T/real" && git init -q && git add -A && git commit -q -m fixture && echo x > code.ts)
stop "$T/real"
[ "$rc" = 0 ] && [ ! -e "$T/real/validate-ran" ] \
  && ok "the real gate, repository untrusted: validate-fast never runs" \
  || bad "the real gate, repository untrusted: validate-fast never runs" "rc=$rc"
trust trusted "$T/repo" "$T/real"
stop "$T/real"
[ "$rc" = 2 ] && [ -e "$T/real/validate-ran" ] && echo "$err" | grep -q "validate:fast FAILED" \
  && ok "the real gate, repository trusted: a red validate-fast blocks the turn" \
  || bad "the real gate, repository trusted: a red validate-fast blocks the turn" "rc=$rc err=$err"

# --- the wrapper's own uncertainty: exit 0, run nothing -------------------------------------------
rm "$T/repo/.quality-kit.json"
stop "$T/repo"
[ "$rc" = 0 ] && ! ran "$T/repo" && ok "a trusted repository without .quality-kit.json is not run" \
  || bad "a trusted repository without .quality-kit.json is not run" "rc=$rc"
(cd "$T/repo" && command git checkout -q -- .quality-kit.json)
set +e; (cd "$T/repo" && printf 'not json' | bash "$HOOK" 2>/dev/null); rc=$?; set -e
[ "$rc" = 0 ] && ! ran "$T/repo" && ok "an unparseable payload exits 0" || bad "an unparseable payload exits 0" "rc=$rc"
set +e; (cd "$T/repo" && printf '{"cwd":"src"}' | bash "$HOOK" 2>/dev/null); rc=$?; set -e
[ "$rc" = 0 ] && ! ran "$T/repo" && ok "a relative cwd exits 0" || bad "a relative cwd exits 0" "rc=$rc"
printf 'not = [toml' > "$CODEX_HOME/config.toml"
stop "$T/repo"
[ "$rc" = 0 ] && ! ran "$T/repo" && ok "an unreadable config exits 0" || bad "an unreadable config exits 0" "rc=$rc"
rm "$CODEX_HOME/config.toml"
stop "$T/repo"
[ "$rc" = 0 ] && ! ran "$T/repo" && ok "no config exits 0" || bad "no config exits 0" "rc=$rc"

# Fresh retained fixtures: trust decision and executed script must name the same LF root.
LF="$(mktemp -d)"
printf 'codex LF fixtures (left intact): %s\n' "$LF"
lf_repo() { # native baseline, no commit hooks or hook override
  mkdir -p "$1/.quality"
  cat > "$1/.quality/stop-validate.sh" <<'EOF'
#!/usr/bin/env bash
printf 'ran\n' > "$WITNESS_NAME"
echo 'LF fixture blocked' >&2
exit 2
EOF
  printf '{}\n' > "$1/.quality-kit.json"
  command git -C "$1" init -q
  command git -C "$1" add -A
  local tree commit
  tree=$(command git -C "$1" write-tree)
  commit=$(printf 'LF baseline\n' | command git -C "$1" -c user.name=t -c user.email=t@t commit-tree "$tree")
  command git -C "$1" update-ref HEAD "$commit"
}
lf_config() { # home, trusted main, optional untrusted worktree
  mkdir -p "$1"
  python3 - "$@" <<'PYCONFIG'
import json, sys
with open(sys.argv[1] + '/config.toml', 'w') as f:
    f.write('[projects.' + json.dumps(sys.argv[2]) + ']\ntrust_level = "trusted"\n')
    if len(sys.argv) > 3:
        f.write('[projects.' + json.dumps(sys.argv[3]) + ']\ntrust_level = "untrusted"\n')
PYCONFIG
}
lf_stop() { # cwd, home, witness name, output file
  set +e
  (cd "$1" && python3 -c 'import json,sys; print(json.dumps({"cwd":sys.argv[1]}))' "$1" | CODEX_HOME="$2" WITNESS_NAME="$3" bash "$HOOK") > "$4" 2>&1
  rc=$?
  set -e
}
lf_root="$LF/trusted"$'\n'
lf_repo "$lf_root"
lf_config "$LF/home-no-sibling" "$lf_root"
lf_stop "$lf_root" "$LF/home-no-sibling" witness-no-sibling "$LF/no-sibling.out"
[ "$rc" = 2 ] && [ -f "$lf_root/witness-no-sibling" ] \
  && ok 'trusted LF root runs when stripped sibling is absent' \
  || bad 'trusted LF root runs when stripped sibling is absent' "rc=$rc witness=$([ -f "$lf_root/witness-no-sibling" ] && echo yes || echo no)"
lf_repo "$LF/trusted"
lf_config "$LF/home-sibling" "$lf_root" "$LF/trusted"
lf_stop "$lf_root" "$LF/home-sibling" witness-sibling "$LF/sibling.out"
[ "$rc" = 2 ] && [ -f "$lf_root/witness-sibling" ] && [ ! -e "$LF/trusted/witness-sibling" ] \
  && ok 'trusted LF root runs, untrusted stripped sibling never runs' \
  || bad 'trusted LF root runs, untrusted stripped sibling never runs' "rc=$rc correct=$([ -f "$lf_root/witness-sibling" ] && echo yes || echo no) wrong=$([ -f "$LF/trusted/witness-sibling" ] && echo yes || echo no)"
lf_main="$LF/main"; lf_link="$LF/linked"$'\n'
lf_repo "$lf_main"
command git -C "$lf_main" worktree add -q --detach "$lf_link"
lf_config "$LF/home-linked" "$lf_main"
lf_stop "$lf_link" "$LF/home-linked" witness-linked "$LF/linked.out"
[ "$rc" = 2 ] && [ -f "$lf_link/witness-linked" ] && [ ! -e "$lf_main/witness-linked" ] \
  && ok 'LF linked worktree inherits main trust and runs its own gate' \
  || bad 'LF linked worktree inherits main trust and runs its own gate' "rc=$rc linked=$([ -f "$lf_link/witness-linked" ] && echo yes || echo no)"
lf_config "$LF/home-untrusted" "$lf_main" "$lf_link"
lf_stop "$lf_link" "$LF/home-untrusted" witness-untrusted "$LF/untrusted.out"
[ "$rc" = 0 ] && [ ! -e "$lf_link/witness-untrusted" ] && [ ! -e "$lf_main/witness-untrusted" ] \
  && ok 'LF linked explicit untrusted overrides main trust' \
  || bad 'LF linked explicit untrusted overrides main trust' "rc=$rc"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
