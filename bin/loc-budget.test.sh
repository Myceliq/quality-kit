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

# --- ts block comment header is free ---
R="$(mkrepo)"
cat > "$R/header.ts" <<'EOF'
/**
 * What: something
 * Where: somewhere
 * Why: issue 66
 */

export const x = 1;
EOF
git -C "$R" add -A
out="$(LOC_PATHS='*.ts' bash "$LB" "$R")"
# header is 5 lines of comment, 1 blank line, export const x = 1 is 1 line -> 1 counted line
echo "$out" | grep -q "^1 tracked source lines" && ok "ts header block comment free" || bad "ts header block comment free" "$out"

# --- ts single-line block comment is free ---
R="$(mkrepo)"
cat > "$R/single.ts" <<'EOF'
/* single-line block comment */
const a = 1;
/* another block comment */
const b = 2;
EOF
git -C "$R" add -A
out="$(LOC_PATHS='*.ts' bash "$LB" "$R")"
# 2 block comments skipped, const a = 1 and const b = 2 counted -> 2 counted lines
echo "$out" | grep -q "^2 tracked source lines" && ok "ts single-line block comment free" || bad "ts single-line block comment free" "$out"

# --- ts code after block-comment close on same line is counted ---
R="$(mkrepo)"
cat > "$R/inline_close.ts" <<'EOF'
/*
 * multi-line block comment
 */ const x = 1;
EOF
git -C "$R" add -A
out="$(LOC_PATHS='*.ts' bash "$LB" "$R")"
# lines 1-2 are block comment, line 3 closes comment and has const x = 1 -> 1 counted line
echo "$out" | grep -q "^1 tracked source lines" && ok "ts code after block comment close counted" || bad "ts code after block comment close counted" "$out"

# --- ts /* inside template literal is counted payload, not comment ---
R="$(mkrepo)"
cat > "$R/template_block.ts" <<'EOF'
const query = `
  /* not a block comment */
  SELECT 1;
`;
EOF
git -C "$R" add -A
out="$(LOC_PATHS='*.ts' bash "$LB" "$R")"
# template literal spans 4 lines (lines 1-4 all counted) -> 4 counted lines
echo "$out" | grep -q "^4 tracked source lines" && ok "ts /* inside template literal counted" || bad "ts /* inside template literal counted" "$out"

# --- ts template literal interpolation with block comment is free ---
R="$(mkrepo)"
cat > "$R/tmpl_interp.ts" <<'EOF'
const x = `${
  /* explanation
  more comment
  */
  value
}`;
EOF
git -C "$R" add -A
out="$(LOC_PATHS='*.ts' bash "$LB" "$R")"
# lines 1, 5, 6 counted; lines 2-4 (block comment) free -> 3 counted lines
echo "$out" | grep -q "^3 tracked source lines" && ok "ts template interpolation comment free" || bad "ts template interpolation comment free" "$out"


# --- ts /* inside quoted strings is string payload, not comment ---
R="$(mkrepo)"
cat > "$R/quoted.ts" <<'EOF'
const s1 = "/* double-quoted block opener";
const s2 = '/* single-quoted block opener';
// real line comment
const s3 = "/* not a comment */";
EOF
git -C "$R" add -A
out="$(LOC_PATHS='*.ts' bash "$LB" "$R")"
# s1, s2, s3 lines counted (3), line comment skipped -> 3 counted lines
echo "$out" | grep -q "^3 tracked source lines" && ok "ts /* inside quoted strings counted" || bad "ts /* inside quoted strings counted" "$out"

# --- ts continued string with trailing backslash preserves quote state ---
R="$(mkrepo)"
cat > "$R/continued_str.ts" <<'EOF'
const s = "line 1 \
/* not a block comment \
line 3";
EOF
git -C "$R" add -A
out="$(LOC_PATHS='*.ts' bash "$LB" "$R")"
# all 3 lines of continued string counted -> 3 counted lines
echo "$out" | grep -q "^3 tracked source lines" && ok "ts continued string /* counted" || bad "ts continued string /* counted" "$out"

# --- ts division followed by block comment enters comment mode ---
R="$(mkrepo)"
cat > "$R/division_comment.ts" <<'EOF'
const x = a / /* explanation
more comment
*/ 2;
const y = a / /* see https://example.com/foo
another comment
*/ 2;
EOF
git -C "$R" add -A
out="$(LOC_PATHS='*.ts' bash "$LB" "$R")"
# (const x = a / /*) and (*/ 2;) for x (2 lines), same for y (2 lines) -> 4 counted lines
echo "$out" | grep -q "^4 tracked source lines" && ok "ts division before block comment enters comment" || bad "ts division before block comment enters comment" "$out"

# --- ts regex with /* inside character class does not open a comment ---
R="$(mkrepo)"
cat > "$R/regex.ts" <<'EOF'
const marker = /[/*]/;
if (ok) /[/*]/.test(value);
if (ok) {}
/[/*]/.test(value);
const ok = value instanceof /[/*]/;
const a = 1;
const b = 2;
EOF
git -C "$R" add -A
out="$(LOC_PATHS='*.ts' bash "$LB" "$R")"
# marker, if 1, if 2 line 1, if 2 line 2, ok, a, b all counted -> 7 counted lines
echo "$out" | grep -q "^7 tracked source lines" && ok "ts regex /* in character class does not open comment" || bad "ts regex /* in character class does not open comment" "$out"

# --- ts generic arrow function followed by block comment ---
R="$(mkrepo)"
cat > "$R/ts_generic.ts" <<'EOF'
const identity = <T,>(x: T) => x;
/* block comment
more comment
*/
const a = 1;
EOF
git -C "$R" add -A
out="$(LOC_PATHS='*.ts' bash "$LB" "$R")"
# identity and const a = 1 counted (2 lines); block comment free -> 2 counted lines
echo "$out" | grep -q "^2 tracked source lines" && ok "ts generic function followed by block comment counted" || bad "ts generic function followed by block comment counted" "$out"

# --- tsx generic arrow with default type parameter ---
R="$(mkrepo)"
cat > "$R/tsx_generic_default.tsx" <<'EOF'
const id = <T = string>(x: T) => x;
/* block comment
more comment
*/
const a = 1;
EOF
git -C "$R" add -A
out="$(LOC_PATHS='*.tsx' bash "$LB" "$R")"
# id and const a = 1 counted (2 lines); block comment free -> 2 counted lines
echo "$out" | grep -q "^2 tracked source lines" && ok "tsx generic arrow with default type param counted" || bad "tsx generic arrow with default type param counted" "$out"

# --- tsx single letter uppercase JSX component with child text ---
R="$(mkrepo)"
cat > "$R/single_letter_jsx.tsx" <<'EOF'
export function Comp() {
  return <X>/* literal text</X>;
}
EOF
git -C "$R" add -A
out="$(LOC_PATHS='*.tsx' bash "$LB" "$R")"
# 3 lines of TSX code -> 3 counted lines
echo "$out" | grep -q "^3 tracked source lines" && ok "tsx single letter JSX component counted" || bad "tsx single letter JSX component counted" "$out"

# --- tsx simple generic arrow function ---
R="$(mkrepo)"
cat > "$R/tsx_simple_generic.tsx" <<'EOF'
const id = <T>(x: T) => x;
/* block comment
more comment
*/
const a = 1;
EOF
git -C "$R" add -A
out="$(LOC_PATHS='*.tsx' bash "$LB" "$R")"
# id and const a = 1 counted (2 lines); block comment free -> 2 counted lines
echo "$out" | grep -q "^2 tracked source lines" && ok "tsx simple generic arrow counted" || bad "tsx simple generic arrow counted" "$out"

# --- tsx attribute expression with regex character class ---
R="$(mkrepo)"
cat > "$R/jsx_attr_regex.tsx" <<'EOF'
export function Comp() {
  return <div pattern={/[/*]/} />;
}
EOF
git -C "$R" add -A
out="$(LOC_PATHS='*.tsx' bash "$LB" "$R")"
# 3 lines of TSX code -> 3 counted lines
echo "$out" | grep -q "^3 tracked source lines" && ok "tsx attr expr with regex counted" || bad "tsx attr expr with regex counted" "$out"



# --- tsx multiline generic arrow function ---
R="$(mkrepo)"
cat > "$R/tsx_multiline_generic.tsx" <<'EOF'
const id = <T,>
(x: T) => x;
/* block comment
more comment
*/
const a = 1;
EOF
git -C "$R" add -A
out="$(LOC_PATHS='*.tsx' bash "$LB" "$R")"
# lines 1, 2, 6 counted (3 lines); block comment free -> 3 counted lines
echo "$out" | grep -q "^3 tracked source lines" && ok "tsx multiline generic arrow counted" || bad "tsx multiline generic arrow counted" "$out"

# --- tsx generic arrow with comment between type and params ---
R="$(mkrepo)"
cat > "$R/tsx_delayed_generic.tsx" <<'EOF'
const id = <T,>
/* explanation */
(x: T) => x;
/* standalone block comment
more comment
*/
const a = 1;
EOF
git -C "$R" add -A
out="$(LOC_PATHS='*.tsx' bash "$LB" "$R")"
# lines 1, 3, 7 counted (3 lines); comments free -> 3 counted lines
echo "$out" | grep -q "^3 tracked source lines" && ok "tsx delayed generic arrow counted" || bad "tsx delayed generic arrow counted" "$out"



# --- tsx generic arrow with comment in type parameters ---
R="$(mkrepo)"
cat > "$R/tsx_generic_comment.tsx" <<'EOF'
const id = <
  /* type */
  T,
>(x: T) => x;
/* block comment
more comment
*/
const a = 1;
EOF
git -C "$R" add -A
out="$(LOC_PATHS='*.tsx' bash "$LB" "$R")"
# lines 1, 3, 4, 8 counted (4 lines); comments free -> 4 counted lines
echo "$out" | grep -q "^4 tracked source lines" && ok "tsx generic with comment in type param counted" || bad "tsx generic with comment in type param counted" "$out"




# --- tsx raw child text with /* does not open block comment ---
R="$(mkrepo)"
cat > "$R/jsx_child.tsx" <<'EOF'
export function Comp() {
  return <div>/* literal text</div>;
}
EOF
git -C "$R" add -A
out="$(LOC_PATHS='*.tsx' bash "$LB" "$R")"
# 3 lines of TSX code -> 3 counted lines
echo "$out" | grep -q "^3 tracked source lines" && ok "tsx raw child text with /* counted" || bad "tsx raw child text with /* counted" "$out"

# --- tsx attribute with expression does not confuse child text /* ---
R="$(mkrepo)"
cat > "$R/jsx_attr_expr.tsx" <<'EOF'
export function Comp() {
  return (
    <div title={name}>
      /* literal child text
    </div>
  );
}
EOF
git -C "$R" add -A
out="$(LOC_PATHS='*.tsx' bash "$LB" "$R")"
# 7 lines of TSX code -> 7 counted lines
echo "$out" | grep -q "^7 tracked source lines" && ok "tsx attr expr with child text /* counted" || bad "tsx attr expr with child text /* counted" "$out"

# --- tsx generic component with type arguments preserves child text ---
R="$(mkrepo)"
cat > "$R/jsx_generic_comp.tsx" <<'EOF'
export function App() {
  return (
    <Foo<T, U>>
      // child line 1
      /* child line 2 */
    </Foo>
  );
}
EOF
git -C "$R" add -A
out="$(LOC_PATHS='*.tsx' bash "$LB" "$R")"
# 8 lines of TSX code including child text -> 8 counted lines
echo "$out" | grep -q "^8 tracked source lines" && ok "tsx generic component with child text counted" || bad "tsx generic component with child text counted" "$out"

# --- tsx attribute with expression containing block comment is free ---
R="$(mkrepo)"
cat > "$R/jsx_attr_comment.tsx" <<'EOF'
export function Comp() {
  return (
    <div value={
      /* multiline explanation */
      value
    }>
      content
    </div>
  );
}
EOF
git -C "$R" add -A
out="$(LOC_PATHS='*.tsx' bash "$LB" "$R")"
# 10 lines, line 4 (/* multiline explanation */) free -> 9 counted lines
echo "$out" | grep -q "^9 tracked source lines" && ok "tsx attr expr with block comment free" || bad "tsx attr expr with block comment free" "$out"





# --- ts regex followed by multiplication across lines ---
R="$(mkrepo)"
cat > "$R/regex_mul.ts" <<'EOF'
const n = /x/*
2;
EOF
git -C "$R" add -A
out="$(LOC_PATHS='*.ts' bash "$LB" "$R")"
# regex line and multiplication operand line both counted -> 2 counted lines
echo "$out" | grep -q "^2 tracked source lines" && ok "ts regex followed by multiplication counted" || bad "ts regex followed by multiplication counted" "$out"

# --- ts control condition call followed by division comment ---
R="$(mkrepo)"
cat > "$R/if_div.ts" <<'EOF'
if (ok) fn() / /* explanation
more comment
*/ 2;
EOF
git -C "$R" add -A
out="$(LOC_PATHS='*.ts' bash "$LB" "$R")"
# line 1 (if fn() / /*) and line 3 (*/ 2;) counted; line 2 (more comment) free -> 2 counted lines
echo "$out" | grep -q "^2 tracked source lines" && ok "ts control call division before comment counted" || bad "ts control call division before comment counted" "$out"

# --- ts division after postfix increment with comment ---
R="$(mkrepo)"
cat > "$R/postfix_div.ts" <<'EOF'
const x = a++ / "foo/*" /* explanation
more comment
*/ 2;
EOF
git -C "$R" add -A
out="$(LOC_PATHS='*.ts' bash "$LB" "$R")"
# line 1 (const x = a++ / "foo/*" /*) and line 3 (*/ 2;) counted; line 2 (more comment) free -> 2 counted lines
echo "$out" | grep -q "^2 tracked source lines" && ok "ts postfix division before comment counted" || bad "ts postfix division before comment counted" "$out"

# --- ts spread operator followed by regex with /* ---
R="$(mkrepo)"
cat > "$R/spread_regex.ts" <<'EOF'
const values = [.../[/*]/];
const a = 1;
const b = 2;
EOF
git -C "$R" add -A
out="$(LOC_PATHS='*.ts' bash "$LB" "$R")"
# values, a, b all counted -> 3 counted lines
echo "$out" | grep -q "^3 tracked source lines" && ok "ts spread regex counted" || bad "ts spread regex counted" "$out"


# --- ts division with regex operand followed by block comment ---
R="$(mkrepo)"
cat > "$R/regex_comment.ts" <<'EOF'
const n = divisor / /x/ /* explanation
more comment
*/ 2;
EOF
git -C "$R" add -A
out="$(LOC_PATHS='*.ts' bash "$LB" "$R")"
# line 1 (const n = divisor / /x/ /*) and line 3 (*/ 2;) counted; line 2 free -> 2 counted lines
echo "$out" | grep -q "^2 tracked source lines" && ok "ts regex operand followed by block comment counted" || bad "ts regex operand followed by block comment counted" "$out"




# --- ts division before quoted url does not trigger false regex/comment ---
R="$(mkrepo)"
cat > "$R/div_url.ts" <<'EOF'
const x = divisor / "https://host/*".length;
const a = 1;
const b = 2;
EOF
git -C "$R" add -A
out="$(LOC_PATHS='*.ts' bash "$LB" "$R")"
# x, a, b all counted -> 3 counted lines
echo "$out" | grep -q "^3 tracked source lines" && ok "ts division before quoted string with /* counted" || bad "ts division before quoted string with /* counted" "$out"




# --- ts unterminated /* at EOF gives its swallowed lines back ---
# a block comment still open at EOF is invalid source or a misread opener; either
# way the lines it ate are unverifiable, so they are counted rather than skipped.
R="$(mkrepo)"
cat > "$R/unterminated.ts" <<'EOF'
const a = 1;
const b = 2;
/* unterminated block comment at end of file
line in unclosed comment
EOF
git -C "$R" add -A
out="$(LOC_PATHS='*.ts' bash "$LB" "$R")"
# lines 1-2 are code (2); lines 3-4 were swallowed by a comment that never closed
# and are handed back rather than silently erased -> 4 counted lines
echo "$out" | grep -q "^4 tracked source lines" && ok "ts unterminated /* at EOF returns swallowed lines" || bad "ts unterminated /* at EOF returns swallowed lines" "$out"


# --- tsx nested JSX in an attribute expression cannot hide the rest of the file ---
# <span> inside child={...} is consumed as tag text, so its raw child text '/*'
# opens a false block comment. Unclosed at EOF, that used to swallow every line
# below it — an unbounded, silent undercount in a budget gate.
R="$(mkrepo)"
cat > "$R/nested.tsx" <<'EOF'
const view = <Comp child={<span>/* literal text</span>} />;
const a = 1;
const b = 2;
const c = 3;
EOF
git -C "$R" add -A
out="$(LOC_PATHS='*.tsx' bash "$LB" "$R")"
echo "$out" | grep -q "^4 tracked source lines" && ok "tsx nested JSX in attr expr does not hide the file" || bad "tsx nested JSX in attr expr does not hide the file" "$out"


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

# --- FACTORY_GATE short-circuits before any measurement (#15) ---
# The factory's gate mounts a content snapshot with no .git, so `git ls-files` fails
# and the budget cannot be measured there. Without the skip this exits 1 and a
# fail-closed gate deadlocks the repo. Two properties, not one: that it skips, AND
# that it emits no summary line — consumers parse that line, and a number nothing
# measured is worse than no number.
R="$(mkrepo)"
printf 'x = 1\n' > "$R/a.py"
git -C "$R" add -A
rm -r "$R/.git"   # what the gate's snapshot looks like: content, no history
rc=0; out="$(LOC_PATHS='*.py' FACTORY_GATE=1 bash "$LB" "$R" 2>&1)" || rc=$?
[ "$rc" = 0 ] && echo "$out" | grep -q "unmeasurable in gate" \
  && ! echo "$out" | grep -q "tracked source lines" \
  && ok "FACTORY_GATE skips before measuring, and prints no summary line" \
  || bad "FACTORY_GATE skip" "rc=$rc out=$out"

# --- gate-ness is never INFERRED from git failing (#15) ---
# The same unmeasurable tree without the flag must still refuse. If a broken git
# implied "in a gate", any broken git anywhere would silently disarm the budget.
R="$(mkrepo)"
printf 'x = 1\n' > "$R/a.py"
git -C "$R" add -A
rm -r "$R/.git"
rc=0; out="$(LOC_PATHS='*.py' bash "$LB" "$R" 2>&1)" || rc=$?
[ "$rc" != 0 ] && ok "an unmeasurable tree without the flag still refuses" \
  || bad "no-flag refusal" "passed without FACTORY_GATE: out=$out"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
