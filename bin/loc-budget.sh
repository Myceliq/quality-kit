#!/usr/bin/env bash
# What: fails when a stamped repo's configured source paths exceed its LoC
#       budget, counting SLOC — blank lines, comment-only lines and Python
#       docstrings are free.
# Where: quality-kit/bin; wire into a stamped repo's CI same as
#        check-drift.sh, or run locally before a push.
# Why: ported from software-factory's scripts/loc-budget.sh (that repo's own
#      gate, issue #190 — a predecessor reached ~15k source by building ahead
#      of need; a blueprint doesn't prevent that, a failing check does). SLOC
#      because the budget and a docstring convention must not fight:
#      documentation should not impede on the logic it documents. Counting is
#      language-aware rather than line-prefix, because every cheap heuristic
#      frees real source: a heredoc body line, a '#' inside a string, a bare
#      string in an `if` body. Ambiguity resolves toward counting.
set -euo pipefail

REPO="${1:?usage: loc-budget.sh <repo>}"
REPO="$(cd "$REPO" && pwd)"

# A stamped repo does NOT always run this against a real checkout, which is what
# the earlier version of this comment assumed when it dropped the skip below.
# Myceliq/software-factory's gate runs a stamped repo's `make validate` against a
# content-materialised snapshot of a commit: clean bytes, deliberately no `.git`.
# That is load-bearing there — it is what stops a worker hiding files behind
# `.gitattributes export-ignore`, and what stops `refs/replace` pointing the gate
# at objects other than the ones being published — so it will not grow a `.git`
# to suit this script. `git ls-files` therefore fails, and with `set -euo
# pipefail` the whole run exits 1: an unmeasurable budget presented as a
# violated one, on a gate that is fail-closed, which deadlocks the repo.
#
# Gate-ness is read from a flag the gate INJECTS, never inferred from git
# failing. Inferring it would mean a broken git anywhere else silently disarms
# the enforcement below — the check would stop checking and report success,
# which is the failure mode this whole file exists to prevent.
#
# The skip returns before any output on purpose: the summary line further down
# is parsed by consumers for `^(\d+) tracked source lines` and `\(budget (\d+)\)`,
# and emitting it here would hand them a number nothing measured.
if [ "${FACTORY_GATE:-}" = 1 ]; then
  echo "budget unmeasurable in gate — enforced in CI"
  exit 0
fi

# Paths and budget: LOC_PATHS / LOC_BUDGET env vars win; otherwise read
# .quality-kit.json's locBudget block; env overrides config, config is the
# repo-committed default. No paths from either source is a loud refusal, not
# a default-everything sweep — a default sweep would silently count
# vendored/generated code and inflate the budget without anyone noticing.
QK="$REPO/.quality-kit.json"
CFG_BUDGET="" CFG_PATHS=""
if [ -f "$QK" ]; then
  CFG_BUDGET="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('locBudget',{}).get('budget',''))" "$QK")"
  CFG_PATHS="$(python3 -c "import json,sys;print(' '.join(json.load(open(sys.argv[1])).get('locBudget',{}).get('paths',[])))" "$QK")"
fi
BUDGET="${LOC_BUDGET:-${CFG_BUDGET:-5000}}"
PATHS="${LOC_PATHS:-$CFG_PATHS}"
[ -n "$PATHS" ] || {
  echo "loc-budget.sh: no source paths configured — set LOC_PATHS (space-separated git pathspecs) or .quality-kit.json's locBudget.paths; a default-everything sweep would count vendored/generated code" >&2
  exit 64
}
read -ra PATH_ARR <<<"$PATHS"

# Summing and sorting happen in python, not awk: a path may contain a
# newline, and a record format that splits on one lets a crafted filename
# inject its own count. A process substitution's exit status is invisible to
# `set -e`, so its failure used to reach the counter as an empty list and
# leave here as a cheerful zero.
list=$(mktemp)
trap 'rm -f "$list"' EXIT
if ! git -C "$REPO" ls-files -z -- "${PATH_ARR[@]}" >"$list"; then
  echo "cannot enumerate tracked files: git ls-files failed here" >&2
  exit 1
fi
mapfile -d '' FILES <"$list"

report=$(cd "$REPO" && python3 - "${FILES[@]}" <<'PY'
import ast
import io
import re
import sys
import token
import tokenize

# Docstrings live only here; a string opening any other body is an expression.
DOCABLE = (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)
NOISE = {tokenize.COMMENT, tokenize.NL, token.NEWLINE, token.INDENT, token.DEDENT,
         token.ENDMARKER}
HEREDOC = re.compile(r"""<<-?\s*(?:'([^']*)'|"([^"]*)"|([A-Za-z_]\w*))""")


def py_lines(src):
    """What: counted lines of Python. Where: the .py branch of count().
    Why: exact by construction — ast knows which strings are docstrings, and a
    '#' inside a string is never a COMMENT token, so payload stays counted."""
    docs = []
    for node in ast.walk(ast.parse(src)):
        if not isinstance(node, DOCABLE) or not node.body:
            continue
        first = node.body[0]
        if isinstance(first, ast.Expr) and isinstance(getattr(first.value, "value", None), str):
            docs.append((first.lineno, first.end_lineno))
    lines = set()
    for t in tokenize.generate_tokens(io.StringIO(src).readline):
        if t.type in NOISE:
            continue
        # Only the docstring's own token is free: a line where it shares space
        # with code still holds code, and the code tokens put it back.
        if t.type == token.STRING and any(a <= t.start[0] <= b for a, b in docs):
            continue
        lines.update(range(t.start[0], t.end[0] + 1))
    return len(lines)


def sh_lines(lines):
    """What: counted lines of shell. Where: the .sh branch of count().
    Why: a heredoc body is data — '#' there is payload and blanks are content —
    so comment stripping has to stop at the opener and resume at the delimiter.
    ponytail: a queue of delimiters, no quoting analysis, so `x << y` or an
    opener inside quotes starts a false heredoc and over-counts to its close or
    to EOF. That is the safe direction; parse shell properly if it ever bites."""
    counted, pending = 0, []
    for line in lines:
        if pending:
            counted += 1
            if pending[0] in (line.strip(), line.lstrip("\t")):
                pending.pop(0)
            continue
        stripped = line.strip()
        if stripped and not stripped.startswith("#"):
            counted += 1
            pending += [a or b or c for a, b, c in HEREDOC.findall(line)]
    return counted


# Keywords and characters that allow a regex literal in JS/TS
REGEX_KEYWORDS = {"return", "case", "throw", "yield", "await", "typeof",
                  "void", "delete", "default", "do", "else", "in",
                  "instanceof", "of", "new"}
REGEX_CHARS = {
    "=", "(", ":", "[", "{", "}", ";", ",",
    "!", "&", "|", "^", "~", "?", "<", ">",
    "+", "-", "*", "%", "/", "\\", "..."
}
CONTROL_KEYWORDS = {"if", "while", "for", "with"}


def js_lines(lines, is_jsx=False):
    """What: counted lines of JS/TS(X). Where: the .js/.ts/.tsx/.jsx branch of
    count(). Why: comments (both '//' and '/* */' blocks) and blank lines are
    free, while template literal bodies and strings are counted payload.
    Block-comment state composes with template literal and quote tracking so
    '/*' inside strings or backtick payloads does not open a comment, while
    comments inside template interpolations ${...} remain free.
    ponytail: regex literals containing /* or // are scanned when preceded by
    an operator, keyword, or control statement so character classes like /[/*]/
    do not open false block comments while division operands followed by quoted
    strings with /* stay in division mode; JSX raw child text containing /* is
    counted as payload when is_jsx is True without mistaking TS generics for JSX;
    a block comment left open at EOF gives its swallowed lines back, so a
    misread opener cannot silently erase the rest of a file;
    when the parser cannot be sure it counts the line, never skips it (the safe
    direction, never undercounts)."""
    counted = 0
    in_comment = False
    swallowed = 0
    in_single_quote, in_double_quote = False, False
    template_stack = []
    prev_char = None
    last_word = ""
    in_word = False
    control_paren_depth = 0
    after_control_paren = False
    jsx_depth = 0
    in_jsx_tag = False
    tag_bracket_depth = 0
    is_closing_tag = False
    is_self_closing = False
    is_generic_tag = False
    jsx_expr_depth = 0

    for line in lines:
        in_template_payload = (len(template_stack) > 0 and template_stack[-1] == 0)
        has_code = in_template_payload or in_single_quote or in_double_quote
        i = 0
        while i < len(line):
            if in_comment:
                if line.startswith("*/", i):
                    in_comment = False
                    swallowed = 0
                    i += 2
                else:
                    i += 1
            elif in_template_payload:
                if line[i] == "\\":
                    i += 2
                elif line.startswith("${", i):
                    template_stack[-1] = 1
                    in_template_payload = False
                    has_code = True
                    prev_char = "{"
                    last_word = ""
                    in_word = False
                    i += 2
                elif line[i] == "`":
                    template_stack.pop()
                    in_template_payload = (len(template_stack) > 0 and template_stack[-1] == 0)
                    has_code = True
                    prev_char = "`"
                    last_word = ""
                    in_word = False
                    i += 1
                else:
                    has_code = True
                    i += 1
            elif in_double_quote:
                if line[i] == "\\":
                    i += 2
                elif line[i] == '"':
                    in_double_quote = False
                    prev_char = '"'
                    last_word = ""
                    in_word = False
                    i += 1
                else:
                    i += 1
            elif in_single_quote:
                if line[i] == "\\":
                    i += 2
                elif line[i] == "'":
                    in_single_quote = False
                    prev_char = "'"
                    last_word = ""
                    in_word = False
                    i += 1
                else:
                    i += 1
            elif is_jsx and jsx_depth > 0 and jsx_expr_depth == 0 and not in_jsx_tag:
                if line[i] == "{":
                    has_code = True
                    jsx_expr_depth += 1
                    prev_char = "{"
                    last_word = ""
                    in_word = False
                    i += 1
                elif line[i] == "<":
                    has_code = True
                    in_jsx_tag = True
                    tag_bracket_depth = 1
                    is_closing_tag = (i + 1 < len(line) and line[i + 1] == "/")
                    is_self_closing = False
                    is_generic_tag = False
                    prev_char = "<"
                    last_word = ""
                    in_word = False
                    i += 1
                else:
                    if not line[i].isspace():
                        has_code = True
                        prev_char = line[i]
                    i += 1
            elif is_jsx and in_jsx_tag:
                if line.startswith("/*", i):
                    in_comment = True
                    i += 2
                elif line.startswith("//", i):
                    break
                elif line[i] == '"':
                    has_code = True
                    in_double_quote = True
                    prev_char = '"'
                    last_word = ""
                    in_word = False
                    i += 1
                elif line[i] == "'":
                    has_code = True
                    in_single_quote = True
                    prev_char = "'"
                    last_word = ""
                    in_word = False
                    i += 1
                elif line[i] == "`" and jsx_expr_depth > 0:
                    has_code = True
                    template_stack.append(0)
                    in_template_payload = True
                    prev_char = "`"
                    last_word = ""
                    in_word = False
                    i += 1
                elif line[i] == "{":
                    has_code = True
                    jsx_expr_depth += 1
                    prev_char = "{"
                    last_word = ""
                    in_word = False
                    i += 1
                elif line[i] == "}":
                    has_code = True
                    if jsx_expr_depth > 0:
                        jsx_expr_depth -= 1
                    prev_char = "}"
                    last_word = ""
                    in_word = False
                    i += 1
                elif line[i] == "<" and jsx_expr_depth == 0:
                    has_code = True
                    tag_bracket_depth += 1
                    prev_char = "<"
                    i += 1
                elif line[i] == "," and jsx_expr_depth == 0 and tag_bracket_depth == 1:
                    has_code = True
                    is_generic_tag = True
                    prev_char = ","
                    i += 1
                elif line[i] == "=" and jsx_expr_depth == 0 and tag_bracket_depth == 1:
                    has_code = True
                    j = i + 1
                    while j < len(line) and line[j].isspace():
                        j += 1
                    if j < len(line) and line[j] not in ('"', "'", "{"):
                        is_generic_tag = True
                    prev_char = "="
                    i += 1
                elif jsx_expr_depth > 0 and line[i] == "/" and not line.startswith("/*", i) and not line.startswith("//", i) and (prev_char is None or prev_char in REGEX_CHARS or last_word in REGEX_KEYWORDS):
                    # Regex literal inside JSX attribute expression e.g. pattern={/[/*]/}
                    has_code = True
                    j = i + 1
                    in_cc = False
                    is_regex = False
                    while j < len(line):
                        if line[j] == "\\":
                            j += 2
                        elif line[j] == "[" and not in_cc:
                            in_cc = True
                            j += 1
                        elif line[j] == "]" and in_cc:
                            in_cc = False
                            j += 1
                        elif line[j] == "/" and not in_cc:
                            j += 1
                            while j < len(line) and line[j].isalpha():
                                j += 1
                            i = j
                            is_regex = True
                            prev_char = "/regex"
                            last_word = ""
                            in_word = False
                            break
                        else:
                            j += 1
                    if not is_regex:
                        prev_char = "/"
                        last_word = ""
                        in_word = False
                        i += 1
                elif line[i] == "/":
                    has_code = True
                    if i + 1 < len(line) and line[i + 1] == ">" and jsx_expr_depth == 0:
                        is_self_closing = True
                    prev_char = "/"
                    i += 1
                elif line[i] == ">" and jsx_expr_depth == 0:
                    has_code = True
                    tag_bracket_depth -= 1
                    if tag_bracket_depth <= 0:
                        in_jsx_tag = False
                        tag_bracket_depth = 0
                        j = i + 1
                        while j < len(line) and line[j].isspace():
                            j += 1
                        if j < len(line) and line[j] == "(":
                            is_generic_tag = True
                        if is_generic_tag:
                            is_generic_tag = False
                        elif is_closing_tag:
                            jsx_depth = max(0, jsx_depth - 1)
                        elif not is_self_closing:
                            jsx_depth += 1
                    prev_char = ">"
                    last_word = ""
                    in_word = False
                    i += 1
                else:
                    c = line[i]
                    if not c.isspace():
                        has_code = True
                        prev_char = c
                        if c.isalnum() or c in "_$":
                            if not in_word:
                                last_word = c
                                in_word = True
                            else:
                                last_word += c
                            if last_word == "extends" and jsx_expr_depth == 0 and tag_bracket_depth == 1:
                                is_generic_tag = True
                        else:
                            in_word = False
                            last_word = ""
                    else:
                        in_word = False
                    i += 1
            else:
                if line.startswith("/*", i):
                    in_comment = True
                    i += 2
                elif line.startswith("//", i):
                    break
                elif line[i] == '"':
                    has_code = True
                    in_double_quote = True
                    prev_char = '"'
                    last_word = ""
                    in_word = False
                    after_control_paren = False
                    i += 1
                elif line[i] == "'":
                    has_code = True
                    in_single_quote = True
                    prev_char = "'"
                    last_word = ""
                    in_word = False
                    after_control_paren = False
                    i += 1
                elif line[i] == "`":
                    has_code = True
                    template_stack.append(0)
                    in_template_payload = True
                    prev_char = "`"
                    last_word = ""
                    in_word = False
                    after_control_paren = False
                    i += 1
                elif len(template_stack) > 0 and template_stack[-1] > 0 and line[i] == "{":
                    template_stack[-1] += 1
                    has_code = True
                    prev_char = "{"
                    last_word = ""
                    in_word = False
                    i += 1
                elif len(template_stack) > 0 and template_stack[-1] > 0 and line[i] == "}":
                    template_stack[-1] -= 1
                    in_template_payload = (template_stack[-1] == 0)
                    has_code = True
                    prev_char = "}"
                    last_word = ""
                    in_word = False
                    i += 1
                elif is_jsx and line[i] == "{" and jsx_depth > 0:
                    has_code = True
                    jsx_expr_depth += 1
                    prev_char = "{"
                    last_word = ""
                    in_word = False
                    i += 1
                elif is_jsx and line[i] == "}" and jsx_expr_depth > 0:
                    has_code = True
                    jsx_expr_depth -= 1
                    prev_char = "}"
                    last_word = ""
                    in_word = False
                    i += 1
                elif is_jsx and line[i] == "<" and (i + 1 < len(line) and (line[i + 1].isalpha() or line[i + 1] in "_$>/")) and (prev_char is None or prev_char in REGEX_CHARS or last_word in REGEX_KEYWORDS or after_control_paren or jsx_depth > 0):
                    has_code = True
                    in_jsx_tag = True
                    tag_bracket_depth = 1
                    is_closing_tag = (i + 1 < len(line) and line[i + 1] == "/")
                    is_self_closing = False
                    is_generic_tag = False
                    prev_char = "<"
                    last_word = ""
                    in_word = False
                    i += 1
                elif line[i] == "/" and not line.startswith("/*", i) and not line.startswith("//", i) and (prev_char is None or
                                         prev_char in REGEX_CHARS or
                                         last_word in REGEX_KEYWORDS or
                                         after_control_paren):
                    has_code = True
                    after_control_paren = False
                    j = i + 1
                    in_cc = False
                    is_regex = False
                    while j < len(line):
                        if line[j] == "\\":
                            j += 2
                        elif line[j] == "[" and not in_cc:
                            in_cc = True
                            j += 1
                        elif line[j] == "]" and in_cc:
                            in_cc = False
                            j += 1
                        elif line[j] == "/" and not in_cc:
                            j += 1
                            while j < len(line) and line[j].isalpha():
                                j += 1
                            i = j
                            is_regex = True
                            prev_char = "/regex"
                            last_word = ""
                            in_word = False
                            break
                        else:
                            j += 1
                    if not is_regex:
                        prev_char = "/"
                        last_word = ""
                        in_word = False
                        i += 1
                else:
                    c = line[i]
                    if c.isspace():
                        in_word = False
                    else:
                        has_code = True
                        if c == "." and prev_char == ".":
                            prev_char = ".."
                        elif c == "." and prev_char == "..":
                            prev_char = "..."
                        elif c == "+" and prev_char == "+":
                            prev_char = "++"
                        elif c == "-" and prev_char == "-":
                            prev_char = "--"
                        else:
                            prev_char = c
                        if c.isalnum() or c in "_$":
                            after_control_paren = False
                            if not in_word:
                                last_word = c
                                in_word = True
                            else:
                                last_word += c
                        else:
                            in_word = False
                            if c == "(":
                                if last_word in CONTROL_KEYWORDS:
                                    control_paren_depth = 1
                                elif control_paren_depth > 0:
                                    control_paren_depth += 1
                                after_control_paren = False
                            elif c == ")":
                                if control_paren_depth > 0:
                                    control_paren_depth -= 1
                                    if control_paren_depth == 0:
                                        after_control_paren = True
                                else:
                                    after_control_paren = False
                            else:
                                after_control_paren = False
                            last_word = ""
                    i += 1

        # Reset quote state at end of line unless continued with trailing backslash
        if in_double_quote and (len(line) - len(line.rstrip("\\"))) % 2 == 0:
            in_double_quote = False
        if in_single_quote and (len(line) - len(line.rstrip("\\"))) % 2 == 0:
            in_single_quote = False

        if has_code:
            counted += 1
        elif in_comment:
            swallowed += 1
    # A block comment still open at EOF is either invalid source or a parser
    # mistake — a JSX construct the tag scanner misread as a comment opener.
    # Either way the lines it ate are unverifiable, so count them rather than
    # let an unbounded stretch of real source vanish from the budget.
    if in_comment:
        counted += swallowed
    return counted


def count(path, src):
    """What: countable lines in one file. Where: called per tracked file below.
    Why: an unknown extension raises KeyError into the raw-count fallback."""
    ext = path.rsplit(".", 1)[-1]
    if ext == "md":
        return len(src.splitlines())
    if ext == "py":
        return py_lines(src)
    return {"sh": sh_lines, "js": js_lines, "ts": js_lines,
            "tsx": lambda lines: js_lines(lines, is_jsx=True),
            "jsx": lambda lines: js_lines(lines, is_jsx=True)}[ext](src.splitlines())


def printable(path):
    """What: a path safe to print. Why: a control character in a filename must
    not become a record separator, or a line, in this script's own output."""
    return "".join(c if c.isprintable() else f"%{ord(c):02X}" for c in path)


rows = []
for path in sys.argv[1:]:
    data = open(path, "rb").read()
    try:
        n = count(path, data.decode("utf-8"))
    except Exception:
        n = len(data.splitlines())  # fail closed: a file we cannot read costs raw
    rows.append((n, path))

print(sum(n for n, _ in rows))
for n, path in sorted(rows, reverse=True)[:10]:
    print(f"{n:6d}  {printable(path)}")
PY
)

total=${report%%$'\n'*}

# No configured tree has zero tracked source, so a zero is proof the
# measurement failed — a git that exits 0 on an empty enumeration included.
if (( total == 0 )); then
  echo "cannot enumerate tracked files: zero counted source lines" >&2
  exit 1
fi

printf '%d tracked source lines (budget %d)\n' "$total" "$BUDGET"

if (( total > BUDGET )); then
  echo
  echo "OVER BUDGET by $(( total - BUDGET )) lines. Largest files (counted lines):"
  printf '%s\n' "${report#*$'\n'}"
  echo
  echo "Refactor and delete: the cap is pressure on logic, not a number to move."
  echo "Raise the budget (LOC_BUDGET, or .quality-kit.json's locBudget.budget) via a PR you argue for."
  exit 1
fi
