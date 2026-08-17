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

# ponytail: software-factory's original carried a FACTORY_GATE skip here —
# its CI runs this inside a container whose linked worktree has no reachable
# .git, so the budget is unmeasurable there and it short-circuited to a loud
# no-op. Factory-specific (the gate injects that flag itself); dropped. A
# kit-stamped repo always runs this against a real checkout.

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


def js_lines(lines):
    """What: counted lines of JS/TS(X). Where: the .js/.ts/.tsx/.jsx branch of
    count(). Why: '//' inside a template literal is payload, so backtick
    parity decides whether a line is comment or content.
    ponytail: parity ignores quoted strings and /* */ blocks, so a backtick in
    a quoted string, or a commented-out block, over-counts — the safe way.
    Sharing this counter for ts/tsx/jsx (not just js) is the same tradeoff: a
    JSX `{/* */}` comment isn't special-cased, so it counts as code — safe
    direction, never undercounts."""
    counted, in_template = 0, False
    for line in lines:
        stripped = line.strip()
        if in_template or (stripped and not stripped.startswith("//")):
            counted += 1
        i = 0
        while i < len(line):
            if line[i] == "\\":
                i += 1
            elif line[i] == "`":
                in_template = not in_template
            elif not in_template and line.startswith("//", i):
                break
            i += 1
    return counted


def count(path, src):
    """What: countable lines in one file. Where: called per tracked file below.
    Why: an unknown extension raises KeyError into the raw-count fallback."""
    ext = path.rsplit(".", 1)[-1]
    if ext == "md":
        return len(src.splitlines())
    if ext == "py":
        return py_lines(src)
    return {"sh": sh_lines, "js": js_lines, "ts": js_lines, "tsx": js_lines,
            "jsx": js_lines}[ext](src.splitlines())


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
