#!/usr/bin/env bash
# What: count lint/type suppression directives in a repo tree, JSON to stdout.
# Where: quality-kit/bin; used by stamp.sh (baseline) and check-drift.sh (budget).
# Why:  "disable the rule" is the classic agent repair-loop shortcut — this
#       makes every new suppression a diff-visible, gated act.
set -euo pipefail
cd "${1:?usage: count-suppressions.sh <repo>}"
EX=(--exclude-dir=node_modules --exclude-dir=.next --exclude-dir=dist
    --exclude-dir=build --exclude-dir=coverage --exclude-dir=.quality
    --exclude-dir=.git --exclude-dir=.venv)
cnt() { grep -ro "${EX[@]}" -E "$1" ${2} . 2>/dev/null | wc -l | tr -d ' ' || true; }
TS='--include=*.ts --include=*.tsx --include=*.js --include=*.jsx'
PY='--include=*.py'
printf '{"oxlint-disable":%s,"ts-expect-error":%s,"ts-ignore":%s,"noqa":%s,"type-ignore":%s}\n' \
  "$(cnt 'oxlint-disable' "$TS")" \
  "$(cnt '@ts-expect-error' "$TS")" \
  "$(cnt '@ts-ignore' "$TS")" \
  "$(cnt '#[[:space:]]*noqa' "$PY")" \
  "$(cnt '#[[:space:]]*type:[[:space:]]*ignore' "$PY")"
