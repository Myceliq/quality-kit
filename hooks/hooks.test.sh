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
mk_repo() { # $1=fail(0|1) → fixture git repo whose validate-fast exits $1
  local r; r="$(mktemp -d)"
  (cd "$r" && git init -q && git commit -q --allow-empty -m init)
  printf '{"version":"0.1.0","profile":"python","runner":"make","pendingFlags":[]}' > "$r/.quality-kit.json"
  printf 'validate-fast:\n\t@exit %s\n' "$1" > "$r/Makefile"
  (cd "$r" && git add -A && git commit -q -m fixture)
  echo "$r"
}
R=$(mk_repo 0)
(cd "$R" && echo '{}' | bash "$SV") && ok "clean tree allows stop" || bad "clean tree allows stop" "blocked"
(cd "$R" && mkdir -p docs && echo x > docs/note.md && echo '{}' | bash "$SV") && ok "docs-only allows stop" || bad "docs-only allows stop" "blocked"
(cd "$R" && echo x > code.ts && echo '{}' | bash "$SV") && ok "dirty+green allows stop" || bad "dirty+green allows stop" "blocked"
RF=$(mk_repo 1)
(cd "$RF" && echo x > code.ts)
set +e; err=$( (cd "$RF" && echo '{}' | bash "$SV") 2>&1 >/dev/null ); rc=$?; set -e
[ "$rc" = 2 ] && echo "$err" | grep -q "validate:fast FAILED" && ok "dirty+red blocks with exit 2" || bad "dirty+red blocks with exit 2" "rc=$rc err=$err"
(cd "$RF" && printf '{"stop_hook_active": true}' | bash "$SV" 2>/dev/null); rc=$?
[ "$rc" = 0 ] && ok "stop_hook_active releases (no livelock)" || bad "stop_hook_active releases (no livelock)" "rc=$rc"
(cd "$(mktemp -d)" && git init -q . && echo '{}' | bash "$SV") && ok "unstamped repo no-op" || bad "unstamped repo no-op" "blocked"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
