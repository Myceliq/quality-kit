#!/usr/bin/env bash
# What: run a stamped repo's linter and aggregate violations per rule, JSON to
#       stdout — the burn-down seed for .quality-kit.json ruleOverrides.
# Where: quality-kit/bin; called by stamp.sh on first stamp and by the operator.
# Why:  onboarding a mature repo means hundreds of pre-existing violations. This
#       turns them into a counted, ratcheting burn-down instead of a red gate or
#       a pile of inline suppressions.
set -euo pipefail

# oxlint diagnostics carry `plugin(rule)`; oxlint CONFIGS key core eslint rules
# bare and every other plugin as `plugin/rule`. Emitting the diagnostic form
# verbatim would produce burn-down keys that no config can ever match.
if [ "${1:-}" = "--norm" ]; then
  python3 -c "
import sys
c = sys.argv[1]
if '(' in c and c.endswith(')'):
    p, r = c[:-1].split('(', 1)
    print(r if p == 'eslint' else f'{p}/{r}')
else:
    print(c)" "${2:?usage: baseline-rules.sh --norm <code>}"
  exit 0
fi

# --select forces specific rules to be counted even when the repo's config
# ignores them. check-drift.sh --ratchet needs exactly that: on python, burn-down
# rules are extend-ignore'd in the rendered ruff.toml and would otherwise count
# as zero. Sharing this script is what keeps one normalizer and one counting
# implementation instead of a second copy inside the gate.
SELECT="" REPO=""
while [ $# -gt 0 ]; do case "$1" in
  --select) SELECT="${2:?--select needs a comma-separated rule list}"; shift 2 ;;
  -*)       echo "unknown flag $1 (usage: baseline-rules.sh <repo> [--select a,b])" >&2; exit 64 ;;
  *)        REPO="$1"; shift ;;
esac; done
[ -n "$REPO" ] || { echo "usage: baseline-rules.sh <repo> [--select a,b]" >&2; exit 64; }
REPO="$(cd "$REPO" && pwd)"
PROFILE="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('profile',''))" "$REPO/.quality-kit.json")"

# A baseline seeded from a dirty tree is not reproducible. CI lints a clean
# checkout, so untracked scratch files and uncommitted edits shift the counts —
# and the ratchet then compares CI's reality against numbers CI can never
# reproduce. Recorded-too-low is the dangerous direction: it fails the gate on a
# PR that changed nothing. Warn on stderr so stdout stays machine-readable.
#
# Warn, do NOT hard-fail. Two reasons, both load-bearing:
#   1. stamp.sh dirties the tree by design (it writes oxlint.config.ts,
#      package.json, tsconfig.json …) and then calls this script. A hard
#      precondition would make stamp-invoked seeding fail 100% of the time.
#   2. A bad baseline cannot reach main anyway: the stamp PR's own CI runs
#      `check-drift.sh --ratchet` post-install against a CLEAN checkout, so a
#      count seeded too low fails that very PR with "burn-down regressed … fix
#      or bump with justification". The gate is self-correcting on the PR that
#      introduces the baseline — which is the real reproducibility check, not
#      tree cleanliness at seed time.
if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
   && [ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ]; then
  echo "baseline-rules.sh: WARNING — working tree is dirty; counts may not match a clean CI checkout. Seed from a clean tree for an authoritative baseline." >&2
fi

if [ "$PROFILE" = python ]; then
  RUFF=""
  command -v ruff >/dev/null 2>&1 && RUFF="ruff"
  [ -z "$RUFF" ] && command -v uvx >/dev/null 2>&1 && RUFF="uvx ruff"
  if [ -z "$RUFF" ]; then
    echo "{}"
    echo "baseline-rules.sh: ruff not on PATH — install it, then run: quality-kit/bin/baseline-rules.sh $REPO" >&2
    exit 3  # distinct from 0 (ok) and 64/65/66 (usage/modified/unstamped): "couldn't count", not "counted zero"
  fi
  # a CLI --select overrides a config-file extend-ignore (verified, ruff 0.15.22)
  set +e
  ERRF="$(mktemp)"
  trap 'rm -f "$ERRF"' EXIT
  RAW="$(cd "$REPO" && $RUFF check ${SELECT:+--select "$SELECT"} --exit-zero --output-format json . 2>"$ERRF")"
  RUFF_RC=$?
  set -e
  # --exit-zero means a genuinely successful ruff run (violations or not)
  # always exits 0 — a non-zero exit here is a real failure (bad config,
  # crash), never "found violations". Emitting {} at exit 0 for that would
  # silently seed a too-low baseline instead of surfacing the failure, so the
  # rc AND the output shape (a JSON list) both gate success; exit 4 signals
  # "ran but failed", distinct from exit 3 ("not installed"). Piped via
  # stdin, not argv: a real repo's lint output can be well past ARG_MAX, and
  # execve() rejects an over-long argument list outright. stderr is captured
  # to a separate file (not merged into RAW) so stdout stays pure JSON — on
  # failure its contents are what actually tell the operator why ruff crashed.
  python3 -c "
import collections, json, sys
rc = int(sys.argv[1])
errf = sys.argv[2]
raw = sys.stdin.read()
diags = None
if rc == 0:
    try:
        d = json.loads(raw)
        if isinstance(d, list):
            diags = d
    except Exception:
        pass
if diags is None:
    print('{}')
    print(f'baseline-rules.sh: ruff check failed to produce a valid rule list (exit {rc}) — not seeding a baseline; fix the failure, then run: quality-kit/bin/baseline-rules.sh $REPO', file=sys.stderr)
    err = open(errf).read().strip()
    print(err[-2000:] if err else raw[-2000:], file=sys.stderr)
    sys.exit(4)
c = collections.Counter(x['code'] for x in diags if x.get('code'))
print(json.dumps(dict(sorted(c.items()))))" "$RUFF_RC" "$ERRF" <<<"$RAW"
  exit 0
fi

# TS profiles ignore --select by design: the stamped config applies burn-down
# rules at `warn`, so they are already present in a normal lint run.

# TS profiles: reuse the repo's own canonical lint script so the counts can never
# drift from what CI actually enforces (it carries --type-aware).
if [ ! -x "$REPO/node_modules/.bin/oxlint" ]; then
  echo "{}"
  echo "baseline-rules.sh: oxlint not installed — run 'npm ci', then run: quality-kit/bin/baseline-rules.sh $REPO" >&2
  exit 3  # distinct from 0 (ok) and 64/65/66 (usage/modified/unstamped): "couldn't count", not "counted zero"
fi
# oxlint (unlike ruff) has no --exit-zero, and a non-zero exit is the NORMAL
# case whenever it finds violations — the exact case this script exists to
# count. So the exit code can't gate success here; `|| true` only stops
# set -e from aborting on that ordinary non-zero exit. The success signal is
# output SHAPE instead: valid {"diagnostics": [...]} means the linter
# genuinely ran (whether it found 0 or N violations); anything else means it
# crashed or the lint script is broken, and turning that into an empty {}
# baseline would silently seed a wrong count instead of surfacing the failure.
RAW="$( (cd "$REPO" && npm run --silent lint -- --format=json) 2>/dev/null || true)"
# piped via stdin, not argv: a real repo's lint output (thousands of
# diagnostics, each carrying file/message/help text) can be megabytes —
# well past ARG_MAX — and execve() rejects an over-long argument list outright.
python3 -c "
import collections, json, sys
raw = sys.stdin.read()
diags = None
try:
    d = json.loads(raw)
    if isinstance(d, dict) and isinstance(d.get('diagnostics'), list):
        diags = d['diagnostics']
except Exception:
    pass
if diags is None:
    print('{}')
    print('baseline-rules.sh: npm run lint -- --format=json did not produce a valid {\"diagnostics\": [...]} payload — linter crashed or is misconfigured; not seeding a baseline; fix the failure, then run: quality-kit/bin/baseline-rules.sh $REPO', file=sys.stderr)
    print(raw[-2000:], file=sys.stderr)
    sys.exit(4)
def norm(code):
    if '(' in code and code.endswith(')'):
        p, r = code[:-1].split('(', 1)
        return r if p == 'eslint' else f'{p}/{r}'
    return code
c = collections.Counter(norm(d['code']) for d in diags if d.get('code'))
print(json.dumps(dict(sorted(c.items()))))" <<<"$RAW"
