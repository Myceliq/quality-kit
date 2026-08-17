#!/usr/bin/env bash
# What: tests for loc-budget.sh. Where: quality-kit/bin.
# Why:  the counting engine is the whole point of the tool; a wrong count in
#       either direction either lets bloat through or blocks a clean PR.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
LB="$DIR/loc-budget.sh"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }

mkrepo() { local d; d="$(mktemp -d)"; git -C "$d" init -q; git -C "$d" config user.email t@t; git -C "$d" config user.name t; echo "$d"; }

# --- python docstrings are free ---
R="$(mkrepo)"
cat > "$R/a.py" <<'EOF'
"""module docstring, free."""


def f():
    """docstring, free."""
    return 1
EOF
git -C "$R" add -A
out="$(LOC_PATHS='*.py' bash "$LB" "$R")" || { bad "python docstring free" "$out"; }
# code-only lines: def f():  return 1  -> 2 counted lines
echo "$out" | grep -q "^2 tracked source lines" && ok "python docstring free" || bad "python docstring free" "$out"

# --- shell heredoc body is counted, including a '#' inside it ---
R="$(mkrepo)"
cat > "$R/b.sh" <<'EOF'
cat <<END
# not a comment, heredoc payload

END
EOF
git -C "$R" add -A
out="$(LOC_PATHS='*.sh' bash "$LB" "$R")"
# cat <<END / # not a comment / blank / END -> 4 counted lines
echo "$out" | grep -q "^4 tracked source lines" && ok "heredoc body counted" || bad "heredoc body counted" "$out"

# --- ts template literal with // inside is counted, not treated as comment ---
R="$(mkrepo)"
printf 'const s = `has // inside`;\n// a real comment\nconst n = 1;\n' > "$R/c.ts"
git -C "$R" add -A
out="$(LOC_PATHS='*.ts' bash "$LB" "$R")"
# line1 + line3 counted, line2 (real //) skipped -> 2
echo "$out" | grep -q "^2 tracked source lines" && ok "ts template literal // counted" || bad "ts template literal // counted" "$out"

# --- over budget: exit 1 ---
R="$(mkrepo)"
printf 'x = 1\ny = 2\nz = 3\n' > "$R/d.py"
git -C "$R" add -A
rc=0; out="$(LOC_PATHS='*.py' LOC_BUDGET=2 bash "$LB" "$R")" || rc=$?
[ "$rc" = 1 ] && echo "$out" | grep -q "OVER BUDGET" && ok "over budget exits 1" || bad "over budget exits 1" "rc=$rc out=$out"

# --- zero counted lines is a measurement failure, not a pass ---
R="$(mkrepo)"
printf '# only a comment\n\n' > "$R/e.sh"
git -C "$R" add -A
rc=0; out="$(LOC_PATHS='*.sh' bash "$LB" "$R" 2>&1)" || rc=$?
[ "$rc" = 1 ] && echo "$out" | grep -q "zero counted source lines" && ok "zero total fails closed" || bad "zero total fails closed" "rc=$rc out=$out"

# --- unconfigured paths: loud refusal, not a default-everything sweep ---
R="$(mkrepo)"
printf 'x = 1\n' > "$R/f.py"
git -C "$R" add -A
rc=0; err="$(bash "$LB" "$R" 2>&1 >/dev/null)" || rc=$?
[ "$rc" = 64 ] && echo "$err" | grep -q "no source paths configured" && ok "unconfigured paths refuses loudly" || bad "unconfigured paths refuses loudly" "rc=$rc err=$err"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
