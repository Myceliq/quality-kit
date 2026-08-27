#!/usr/bin/env bash
# What: tests for count-suppressions.sh. Where: quality-kit/bin.
# Why:  the suppression budget is a security-relevant gate — an undercount
#       lets agents smuggle disables past CI.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/src" "$T/node_modules/pkg" "$T/docs"
git -C "$T" init -q
printf 'node_modules/\n' > "$T/.gitignore"
cat > "$T/src/a.ts" <<'EOF'
// oxlint-disable-next-line no-explicit-any
const x: any = 1;
// @ts-expect-error legacy shim
const y = x.q;
// @ts-ignore
const z = y;
EOF
printf 'v = 1  # noqa: E501\nw = 2  # type: ignore\n' > "$T/src/b.py"
printf '// oxlint-disable everything\n' > "$T/node_modules/pkg/c.ts"   # gitignored: must NOT count
printf '// @ts-expect-error\nexport {};\n' > "$T/src/c.mts"
printf '// @ts-ignore\nconst w = 1;\n' > "$T/src/untracked.ts"        # written but never `git add`ed: must still count
git -C "$T" add src/a.ts src/b.py src/c.mts .gitignore   # src/untracked.ts deliberately left unstaged

out="$(bash "$DIR/count-suppressions.sh" "$T")"
expected='{"oxlint-disable":1,"ts-expect-error":2,"ts-ignore":2,"noqa":1,"type-ignore":1}'
[ "$out" = "$expected" ] \
  && ok "counts tracked + untracked-but-real files, gitignored dir excluded" || bad "counts tracked + untracked-but-real files, gitignored dir excluded" "$out"

mkdir -p "$T/.claude/worktrees"
git -C "$T" -c core.hooksPath=/dev/null -c user.name=test -c user.email=test@example.com commit -qm fixture
git -C "$T" worktree add -q "$T/.claude/worktrees/copy" -b nested-copy
out_nested="$(bash "$DIR/count-suppressions.sh" "$T")"
[ "$out_nested" = "$out" ] \
  && ok "nested checkout is not counted" || bad "nested checkout is not counted" "$out_nested"

EMPTY="$(mktemp -d)"
git -C "$EMPTY" init -q
out2="$(bash "$DIR/count-suppressions.sh" "$EMPTY")"
[ "$out2" = '{"oxlint-disable":0,"ts-expect-error":0,"ts-ignore":0,"noqa":0,"type-ignore":0}' ] \
  && ok "empty repo all zeros" || bad "empty repo all zeros" "$out2"

NOT_GIT="$(mktemp -d)"
if err="$(bash "$DIR/count-suppressions.sh" "$NOT_GIT" 2>&1)"; then
  bad "outside git repo fails" "unexpected success: $err"
elif [[ "$err" == *"cannot enumerate tracked files"* ]]; then
  ok "outside git repo fails"
else
  bad "outside git repo fails" "$err"
fi

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
