#!/usr/bin/env bash
# What: tests for quality-kit hook scripts. Where: quality-kit/hooks. Why: hooks
# run on every agent turn — silent breakage here disables the whole gate layer.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }

# --- format-changed.sh: routes by extension via a PATH shim, never fails ---
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/repo/node_modules/.bin"
# shim: record invocations instead of really formatting
cat >"$T/repo/node_modules/.bin/oxfmt" <<'EOF'
#!/usr/bin/env bash
echo "oxfmt $*" >> "$SHIM_LOG"
EOF
cat >"$T/bin/ruff" <<'EOF'
#!/usr/bin/env bash
echo "ruff $*" >> "$SHIM_LOG"
EOF
chmod +x "$T/repo/node_modules/.bin/oxfmt" "$T/bin/ruff"
export SHIM_LOG="$T/log"; export PATH="$T/bin:$PATH"
touch "$T/repo/a.ts" "$T/repo/b.py" "$T/repo/c.lock"

(cd "$T/repo" && bash "$DIR/format-changed.sh" a.ts b.py c.lock)
grep -q "oxfmt a.ts" "$SHIM_LOG" && ok "ts routed to oxfmt" || bad "ts routed to oxfmt" "$(cat "$SHIM_LOG")"
grep -q "ruff format b.py" "$SHIM_LOG" && ok "py routed to ruff" || bad "py routed to ruff" "$(cat "$SHIM_LOG")"
grep -q "c.lock" "$SHIM_LOG" && bad "lock skipped" "was formatted" || ok "lock skipped"

(cd "$T/repo" && bash "$DIR/format-changed.sh" missing.ts) && ok "missing file no-op" || bad "missing file no-op" "exited nonzero"

# --- adapter: stdin JSON → file path ---
: > "$SHIM_LOG"
(cd "$T/repo" && printf '{"tool_input":{"file_path":"a.ts"}}' | bash "$DIR/format-changed-adapter.sh")
grep -q "oxfmt a.ts" "$SHIM_LOG" && ok "adapter extracts file_path" || bad "adapter extracts file_path" "$(cat "$SHIM_LOG")"
printf '{"no":"path"}' | bash "$DIR/format-changed-adapter.sh" && ok "adapter no-path no-op" || bad "adapter no-path no-op" "exited nonzero"

# --- stop-validate.sh: diff-aware turn-end gate ---
SV="$DIR/stop-validate.sh"
mk_repo() { # $1=fail(0|1) → fixture git repo whose validate-fast exits $1; any failed step → rc 1, no path
  # Checked explicitly: callers run this inside $( ), where set -e does not reach.
  # The hook is installed where the stamp puts it, .quality/stop-validate.sh, and run from there:
  # it validates only the project it is installed in. validate-fast leaves `validate-ran` behind,
  # so an arm can tell "ran and passed" from "never ran".
  local r; r="$(mktemp -d)" || return 1
  (cd "$r" && git init -q && git config core.hooksPath /dev/null && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init) || return 1
  printf '{"version":"0.1.0","profile":"python","runner":"make","pendingFlags":[]}' > "$r/.quality-kit.json" || return 1
  printf 'validate-fast:\n\t@touch validate-ran; exit %s\n' "$1" > "$r/Makefile" || return 1
  mkdir "$r/.quality" && cp "$SV" "$r/.quality/stop-validate.sh" || return 1
  (cd "$r" && git add -A && git -c user.name=t -c user.email=t@t commit -q -m fixture) || return 1
  [ "$(git -C "$r" rev-list --count HEAD 2>/dev/null)" = 2 ] || return 1
  echo "$r"
}
fixture() { # $1=var $2=fail(0|1) → $1 := mk_repo $2, logged; a build failure stops the suite here
  local r
  r=$(mk_repo "$2") || { echo "FAIL fixture repo: validate-fast exit $2 was not built"; exit 1; }
  printf -v "$1" '%s' "$r"
  ok "fixture repo created: validate-fast exit $2, 2 commits"
}
# mk_repo fails closed: a failed step yields a non-zero status and no path, so no arm below can run
# against a half-built repo. The shim refuses every commit, as git does when it has no identity.
mkdir -p "$T/nocommit"
cat >"$T/nocommit/git" <<EOF
#!/usr/bin/env bash
for a; do [ "\$a" = commit ] && { echo "shim: commit refused" >&2; exit 1; }; done
exec "$(command -v git)" "\$@"
EOF
chmod +x "$T/nocommit/git"
set +e; out=$(PATH="$T/nocommit:$PATH" mk_repo 0 2>/dev/null); rc=$?; set -e
[ "$rc" != 0 ] && [ -z "$out" ] && ok "mk_repo fails closed on a refused commit" \
  || bad "mk_repo fails closed on a refused commit" "rc=$rc out=$out"
H=.quality/stop-validate.sh
fixture R 0
(cd "$R" && echo '{}' | bash $H) && ok "clean tree allows stop" || bad "clean tree allows stop" "blocked"
(cd "$R" && mkdir -p docs && echo x > docs/note.md && echo '{}' | bash $H) && ok "docs-only allows stop" || bad "docs-only allows stop" "blocked"
(cd "$R" && echo x > code.ts && echo '{}' | bash $H) && [ -e "$R/validate-ran" ] \
  && ok "dirty+green allows stop" || bad "dirty+green allows stop" "blocked, or validate-fast never ran"
fixture RF 1
(cd "$RF" && echo x > code.ts)
set +e; err=$( (cd "$RF" && echo '{}' | bash $H) 2>&1 >/dev/null ); rc=$?; set -e
[ "$rc" = 2 ] && echo "$err" | grep -q "validate:fast FAILED" && ok "dirty+red blocks with exit 2" || bad "dirty+red blocks with exit 2" "rc=$rc err=$err"
set +e; (cd "$RF" && printf '{"stop_hook_active": true}' | bash $H 2>/dev/null); rc=$?; set -e
[ "$rc" = 0 ] && ok "stop_hook_active releases (no livelock)" || bad "stop_hook_active releases (no livelock)" "rc=$rc"

# Runner configuration is checked only when validation is required. Build this baseline
# with Git plumbing so no product or fixture commit hooks are bypassed.
C="$T/config-repo"; mkdir -p "$C/.quality" "$T/runner-bin"
cp "$SV" "$C/.quality/stop-validate.sh"
printf '{}\n' > "$C/.quality-kit.json"
printf 'baseline\n' > "$C/code.ts"
git -C "$C" init -q
git -C "$C" add -A
tree=$(git -C "$C" write-tree)
commit=$(printf 'config baseline\n' | git -C "$C" -c user.name=t -c user.email=t@t commit-tree "$tree")
git -C "$C" update-ref HEAD "$commit"
printf 'dirty\n' > "$C/code.ts"
for tool in npm make; do
  cat > "$T/runner-bin/$tool" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$0") $*" > runner-witness
exit "${RUNNER_EXIT:-0}"
EOF
  chmod +x "$T/runner-bin/$tool"
done
config_stop() {
  rm -f "$C/runner-witness"
  set +e
  err=$(cd "$C" && printf '%s' "${1:-'{}'}" | PATH="$T/runner-bin:$PATH" bash "$H" 2>&1)
  rc=$?
  set -e
}
case_no=0
for config in '{' 'null' '[]' '42' '"scalar"' \
  '{"runner":null}' '{"runner":true}' '{"runner":[]}' '{"runner":{}}' \
  '{"runner":"secret-marker"}' '{"runner":""}' '{"runner":" "}' '{"runner":"npm\n"}'; do
  case_no=$((case_no + 1))
  printf '%s' "$config" > "$C/.quality-kit.json"
  config_stop '{}'
  [ "$rc" = 2 ] && [ ! -e "$C/runner-witness" ] && echo "$err" | grep -qi 'config' && ! echo "$err" | grep -q 'secret-marker' \
    && ok "invalid runner config blocks: case $case_no" || bad "invalid runner config blocks: case $case_no" "rc=$rc err=$err"
done
printf '%s' '{"runner":"make"}' > "$C/.quality-kit.json"
chmod 000 "$C/.quality-kit.json"
config_stop '{}'
chmod 600 "$C/.quality-kit.json"
[ "$rc" = 2 ] && [ ! -e "$C/runner-witness" ] && echo "$err" | grep -qi 'config' \
  && ok 'unreadable config blocks' || bad 'unreadable config blocks' "rc=$rc err=$err"
for config in '{}' '{"runner":"npm"}' '{"runner":"make"}'; do
  printf '%s' "$config" > "$C/.quality-kit.json"
  config_stop '{}'
  expected='npm run --silent validate:fast'; [ "$config" != '{"runner":"make"}' ] || expected='make validate-fast'
  [ "$rc" = 0 ] && [ -f "$C/runner-witness" ] && [ "$(cat "$C/runner-witness")" = "$expected" ] \
    && ok "valid runner dispatch: $config" || bad "valid runner dispatch: $config" "rc=$rc err=$err"
done
printf '%s' '{"runner":"npm"}' > "$C/.quality-kit.json"
export RUNNER_EXIT=1
config_stop '{}'
[ "$rc" = 2 ] && [ -f "$C/runner-witness" ] && echo "$err" | grep -q 'validate:fast FAILED' \
  && ok 'npm runner failure blocks' || bad 'npm runner failure blocks' "rc=$rc err=$err"
config_stop '{"stop_hook_active":true}'
[ "$rc" = 0 ] && [ -f "$C/runner-witness" ] && echo "$err" | grep -q 'releasing stop' \
  && ok 'npm runner failure active-stop releases' || bad 'npm runner failure active-stop releases' "rc=$rc err=$err"
unset RUNNER_EXIT
printf '%s' '{"runner":"secret-marker"}' > "$C/.quality-kit.json"
config_stop '{"stop_hook_active":true}'
[ "$rc" = 0 ] && [ ! -e "$C/runner-witness" ] && echo "$err" | grep -qi 'releasing stop' && ! echo "$err" | grep -q 'secret-marker' \
  && ok 'invalid config active-stop releases explicitly' || bad 'invalid config active-stop releases explicitly' "rc=$rc err=$err"

# Keep these pathname fixtures outside the legacy suite's cleanup directory for inspection.
N="$(mktemp -d)"
printf 'pathname fixtures (left intact): %s\n' "$N"
newline_primary="$N/primary"
newline_linked="$N/linked"$'\n'
newline_root="$N/root"$'\n'
newline_fixture() { # $1=repo root, baseline made with plumbing only
  mkdir -p "$1/.quality" "$1/nested"
  cp "$SV" "$1/.quality/stop-validate.sh"
  printf '{"runner":"make"}\n' > "$1/.quality-kit.json"
  printf 'validate-fast:\n\t@touch validate-ran; exit 1\n' > "$1/Makefile"
  printf 'baseline\n' > "$1/nested/code.ts"
  git -C "$1" init -q
  git -C "$1" add -A
  local tree commit
  tree=$(git -C "$1" write-tree)
  commit=$(printf 'pathname baseline\n' | git -C "$1" -c user.name=t -c user.email=t@t commit-tree "$tree")
  git -C "$1" update-ref HEAD "$commit"
}
newline_fixture "$newline_primary"
git -C "$newline_primary" worktree add -q --detach "$newline_linked"
printf 'dirty\n' > "$newline_linked/nested/code.ts"
set +e
err=$(cd "$newline_primary" && python3 -c 'import json,sys; print(json.dumps({"cwd":sys.argv[1]}))' "$newline_linked" | bash "$H" 2>&1); rc=$?
set -e
[ "$rc" = 2 ] && [ -e "$newline_linked/validate-ran" ] && [ ! -e "$newline_primary/validate-ran" ] \
  && ok 'newline linked root validates linked tree, not clean primary' \
  || bad 'newline linked root validates linked tree, not clean primary' "rc=$rc linked=$([ -e "$newline_linked/validate-ran" ] && echo yes || echo no) primary=$([ -e "$newline_primary/validate-ran" ] && echo yes || echo no) err=$err"
newline_fixture "$newline_root"
printf 'dirty\n' > "$newline_root/nested/code.ts"
set +e
err=$(cd "$newline_root/nested" && printf '{}' | bash ../.quality/stop-validate.sh 2>&1); rc=$?
set -e
[ "$rc" = 2 ] && [ -e "$newline_root/validate-ran" ] \
  && ok 'newline primary root selected from nested fallback cwd' \
  || bad 'newline primary root selected from nested fallback cwd' "rc=$rc witness=$([ -e "$newline_root/validate-ran" ] && echo yes || echo no) err=$err"

rename_case() { # source, destination, expected exit
  local src=$1 dst=$2 expected=$3 tree commit rc err
  fixture RR 1
  mkdir -p "$RR/$(dirname "$src")" "$RR/$(dirname "$dst")"
  printf 'rename content\n' > "$RR/$src"
  git -C "$RR" add -- "$src"
  tree=$(git -C "$RR" write-tree)
  commit=$(printf 'rename baseline\n' | git -C "$RR" -c user.name=t -c user.email=t@t commit-tree "$tree" -p HEAD)
  git -C "$RR" update-ref HEAD "$commit"
  git -C "$RR" mv -- "$src" "$dst"
  set +e; err=$(cd "$RR" && echo '{}' | bash "$H" 2>&1); rc=$?; set -e
  if [ "$rc" = "$expected" ] && { { [ "$expected" = 0 ] && [ ! -e "$RR/validate-ran" ]; } || { [ "$expected" = 2 ] && [ -e "$RR/validate-ran" ]; }; }; then
    ok "rename $src -> $dst: exit $expected"
  else
    bad "rename $src -> $dst" "rc=$rc expected=$expected err=$err"
  fi
}
rename_case 'scripts/example.ts' 'scripts/example.md' 2
rename_case 'scripts/example.md' 'scripts/example.ts' 2
rename_case 'docs/example.txt' 'docs/example.md' 0
rename_case $'scripts/a " -> b\n.ts' $'scripts/a " -> b\n.md' 2
rename_case $'docs/a " -> b\n.txt' $'docs/a " -> b\n.md' 0

# A failed or malformed status must not be mistaken for a clean/docs-only tree.
mkdir -p "$T/status-bin"
cat > "$T/status-bin/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = status ]; then
  if [ "\${BAD_STATUS:-}" = malformed ]; then printf 'R  docs/dest.md\\0'; exit 0; fi
  if [ "\${BAD_STATUS:-}" = record ]; then cat "$T/status-record"; exit 0; fi
  exit 1
fi
exec "$(command -v git)" "\$@"
EOF
chmod +x "$T/status-bin/git"
for mode in failed malformed; do
  rm -f "$RF/validate-ran"
  set +e; (cd "$RF" && echo '{}' | BAD_STATUS="$mode" PATH="$T/status-bin:$PATH" bash "$H" 2>/dev/null); rc=$?; set -e
  [ "$rc" = 2 ] && [ -e "$RF/validate-ran" ] && ok "$mode status validates" \
    || bad "$mode status validates" "rc=$rc"
done

# Synthetic porcelain records exercise malformed docs-looking paths and copy sources.
status_record() { # description, expected exit; caller writes the NUL records first
  local label=$1 expected=$2 rc
  rm -f "$RF/validate-ran"
  set +e; (cd "$RF" && echo '{}' | BAD_STATUS=record PATH="$T/status-bin:$PATH" bash "$H" 2>/dev/null); rc=$?; set -e
  if [ "$rc" = "$expected" ] && { { [ "$expected" = 2 ] && [ -e "$RF/validate-ran" ]; } || { [ "$expected" = 0 ] && [ ! -e "$RF/validate-ran" ]; }; }; then
    ok "$label"
  else
    bad "$label" "rc=$rc expected=$expected"
  fi
}
for path in 'docs/../src.ts' 'docs/./note.md' 'docs//note.md' '/docs/note.md' 'docs/note.md/'; do
  printf ' M %s\0' "$path" > "$T/status-record"
  status_record "invalid path $path validates" 2
done
printf 'RR docs/dest.md\0docs/source.md\0' > "$T/status-record"
status_record 'invalid status combination validates' 2
printf 'R  docs/dest.md\0docs/../source.md\0' > "$T/status-record"
status_record 'invalid rename source validates' 2
printf 'C  docs/dest.md\0src/source.ts\0' > "$T/status-record"
status_record 'copy source code validates' 2
printf 'C  docs/dest.md\0docs/source.txt\0' > "$T/status-record"
status_record 'docs-only copy skips' 0
printf 'C  docs/dest.md\0docs/../source.md\0' > "$T/status-record"
status_record 'invalid copy source validates' 2
U="$(mktemp -d)"
(cd "$U" && git init -q . && mkdir .quality && cp "$SV" $H && echo '{}' | bash $H) && ok "unstamped repo no-op" || bad "unstamped repo no-op" "blocked"

# The payload's cwd — not the hook's — picks the tree. A session working in a linked worktree must
# not be blocked by whatever happens to be dirty in the project dir the runtime launched the hook
# from, which on a shared checkout is a peer session's in-flight work.
git -C "$RF" worktree add -q --detach "$T/wgreen"
printf 'validate-fast:\n\t@touch validate-ran; exit 0\n' > "$T/wgreen/Makefile"   # dirty and green
(cd "$RF" && printf '{"cwd":"%s"}' "$T/wgreen" | bash $H) && [ -e "$T/wgreen/validate-ran" ] \
  && ok "payload cwd selects the session's own worktree" \
  || bad "payload cwd selects the session's own worktree" \
         "blocked on the project dir's tree, or the worktree was never validated"

# The hook validates its own project and that project's linked worktrees, and no other repository.
# One project P, clean, so nothing below is decided by its own tree. The two arms run the same
# hook from the same cwd over trees with byte-identical fixtures (dirty, validate-fast writes
# `validate-ran` and exits 1); they differ only in the payload's cwd.
fixture P 1
fixture OTHER 1
git -C "$P" worktree add -q --detach "$T/wred"
echo x > "$T/wred/code.ts"; echo x > "$OTHER/code.ts"
stop_in() { set +e; err=$( (cd "$P" && printf '{"cwd":"%s"}' "$1" | bash $H) 2>&1 >/dev/null ); rc=$?; set -e; }
stop_in "$T/wred"
[ "$rc" = 2 ] && echo "$err" | grep -q "validate:fast FAILED" && [ -e "$T/wred/validate-ran" ] \
  && ok "payload cwd in a linked worktree of the project still blocks when red" \
  || bad "payload cwd in a linked worktree of the project still blocks when red" "rc=$rc err=$err"
stop_in "$OTHER"
[ "$rc" = 0 ] && [ ! -e "$OTHER/validate-ran" ] \
  && ok "payload cwd in another repository is not validated" \
  || bad "payload cwd in another repository is not validated" \
         "rc=$rc validate-ran=$([ -e "$OTHER/validate-ran" ] && echo present || echo absent)"
# The same worktree reached through a symlink is still the project's.
rm -f "$T/wred/validate-ran"; ln -s "$T/wred" "$T/wlink"
stop_in "$T/wlink"
[ "$rc" = 2 ] && [ -e "$T/wred/validate-ran" ] \
  && ok "a symlinked path to the project's worktree is still validated" \
  || bad "a symlinked path to the project's worktree is still validated" "rc=$rc err=$err"

# A cwd that is absent, empty or gone falls back to the hook's own cwd — never silently skips.
set +e; (cd "$RF" && printf '{"cwd":"/nonexistent/%s"}' "$$" | bash $H 2>/dev/null); rc=$?; set -e
[ "$rc" = 2 ] && ok "missing cwd falls back to the hook's cwd" \
  || bad "missing cwd falls back to the hook's cwd" "rc=$rc (a skipped gate, not a pass)"
set +e; (cd "$RF" && printf '{"cwd":""}' | bash $H 2>/dev/null); rc=$?; set -e
[ "$rc" = 2 ] && ok "empty cwd falls back to the hook's cwd" \
  || bad "empty cwd falls back to the hook's cwd" "rc=$rc (a skipped gate, not a pass)"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
