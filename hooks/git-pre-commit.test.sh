#!/usr/bin/env bash
# What: tests for the quality-kit block in the global git pre-commit.
# Where: quality-kit/hooks. Why: pre-commit is the universal delegate gate —
# it must fire for stamped repos and stay a no-op for everything else.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$DIR/git-pre-commit"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"; printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/codex"; chmod +x "$T/bin/codex"
export PATH="$T/bin:$PATH"

mk() { # $1=fail(0|1) → stamped fixture with make runner
  local r; r="$(mktemp -d)"
  (cd "$r" && git init -q && git config core.hooksPath /dev/null && git -c user.name=ci -c user.email=ci@example.com commit -q --allow-empty -m init)
  printf '{"version":"0.1.0","profile":"python","runner":"make","pendingFlags":[]}' > "$r/.quality-kit.json"
  printf 'validate-fast:\n\t@exit %s\n' "$1" > "$r/Makefile"
  echo "$r"
}

R="$(mk 0)"; (cd "$R" && echo x > f.txt && git add f.txt && bash "$HOOK") \
  && ok "stamped+green commit allowed" || bad "stamped+green commit allowed" "blocked"
R="$(mk 1)"; rc=0; (cd "$R" && echo x > f.txt && git add f.txt && bash "$HOOK" 2>/dev/null) || rc=$?
[ "$rc" != 0 ] && ok "stamped+red commit blocked" || bad "stamped+red commit blocked" "allowed"
U="$(mktemp -d)"; (cd "$U" && git init -q && git config core.hooksPath /dev/null && echo x > f.txt && git add f.txt && bash "$HOOK") \
  && ok "unstamped repo unaffected" || bad "unstamped repo unaffected" "blocked"

# Regression: repo path containing a shell-metachar quote must not break runner
# detection (a naive python3 -c "...'$PATH'..." interpolation breaks here and
# silently falls back to npm, skipping the configured make runner).
Q="$T/qu'ote"; mkdir -p "$Q"
(cd "$Q" && git init -q && git config core.hooksPath /dev/null && git -c user.name=ci -c user.email=ci@example.com commit -q --allow-empty -m init)
printf '{"version":"0.1.0","profile":"python","runner":"make","pendingFlags":[]}' > "$Q/.quality-kit.json"
printf 'validate-fast:\n\t@exit 1\n' > "$Q/Makefile"
rc=0; (cd "$Q" && echo x > f.txt && git add f.txt && bash "$HOOK" 2>/dev/null) || rc=$?
[ "$rc" != 0 ] && ok "quoted repo path still resolves runner (blocked as make, not npm no-op)" \
  || bad "quoted repo path still resolves runner" "allowed (runner detection silently fell back)"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
