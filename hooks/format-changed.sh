#!/usr/bin/env bash
# What: format the given files by extension (oxfmt for web, ruff for py).
# Where: stamped as .quality/format-changed.sh; called by agent PostToolUse hooks.
# Why:  best-effort convenience — never blocks an edit; validate enforces later.
set -uo pipefail
for f in "$@"; do
  [ -f "$f" ] || continue
  case "$f" in
    *.ts|*.tsx|*.js|*.jsx|*.mjs|*.cjs|*.json|*.jsonc|*.md|*.css|*.yml|*.yaml)
      npx --no-install oxfmt "$f" >/dev/null 2>&1 || true ;;
    *.py)
      ruff format "$f" >/dev/null 2>&1 || true ;;
  esac
done
exit 0
