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

# An unreadable tracked file must fail the script loudly, not silently read
# as "zero matches in that file" — the exact undercount this gate exists to
# prevent (grep exit 1 "no match" and exit 2 "error" are indistinguishable
# once xargs has batched several files into one invocation). A dangling
# symlink, not chmod 000: chmod is a no-op for root / CAP_DAC_OVERRIDE, so a
# permission-bit fixture would falsely fail this suite under privileged CI —
# a broken symlink is unreadable to everyone, root included. It also directly
# exercises the case the readability check's `-L` guard exists for: `-e`
# alone follows the link and reports a dangling one as simply absent, which
# would wrongly wave a real (if broken) tracked entry through unchecked.
U="$(mktemp -d)"
git -C "$U" init -q
printf '// @ts-expect-error\nexport {};\n' > "$U/a.ts"
ln -s /nonexistent-target-xyz "$U/b.ts"
git -C "$U" add -A
if err="$(bash "$DIR/count-suppressions.sh" "$U" 2>&1)"; then
  bad "unreadable tracked file fails loudly" "unexpected success: $err"
elif [[ "$err" == *"unreadable"* ]]; then
  ok "unreadable tracked file fails loudly"
else
  bad "unreadable tracked file fails loudly" "$err"
fi

# A tracked path that resolves to a directory (a symlink pointing at one, or
# a gitlink) must fail loudly too — `-r` alone reports a directory as
# "readable", but grep fails to open it non-recursively ("Is a directory"),
# a real error the `|| true` would otherwise swallow into the same silent zero.
D="$(mktemp -d)"
git -C "$D" init -q
printf '// @ts-expect-error\nexport {};\n' > "$D/a.ts"
mkdir "$D/dir"
ln -s dir "$D/linkdir.ts"
git -C "$D" add -A
if err="$(bash "$DIR/count-suppressions.sh" "$D" 2>&1)"; then
  bad "symlink to a directory fails loudly" "unexpected success: $err"
elif [[ "$err" == *"unreadable"* ]]; then
  ok "symlink to a directory fails loudly"
else
  bad "symlink to a directory fails loudly" "$err"
fi

# ...and the opposite edge: a tracked file `rm`'d without `git rm` is
# genuinely gone, not a permission problem, and must NOT trip that check —
# it's exactly as absent to grep as it always was (regression coverage: this
# is what check-drift.test.sh's own fresh() fixtures do before writing a
# replacement file, and the first version of the readability check broke it).
R2="$(mktemp -d)"
git -C "$R2" init -q
printf '// @ts-expect-error\nexport {};\n' > "$R2/a.ts"
printf '// @ts-expect-error\nexport {};\n' > "$R2/b.ts"
git -C "$R2" add -A
git -C "$R2" -c core.hooksPath=/dev/null -c user.name=test -c user.email=test@example.com commit -qm fixture
rm "$R2/b.ts"
out3="$(bash "$DIR/count-suppressions.sh" "$R2")"
[ "$out3" = '{"oxlint-disable":0,"ts-expect-error":1,"ts-ignore":0,"noqa":0,"type-ignore":0}' ] \
  && ok "a plain rm of a tracked file stays silent, not a permission error" || bad "a plain rm of a tracked file stays silent, not a permission error" "$out3"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
