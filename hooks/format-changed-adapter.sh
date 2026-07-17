#!/usr/bin/env bash
# What: hook-protocol shim — reads the tool-use JSON on stdin, formats the file.
# Where: stamped as .quality/format-changed-adapter.sh (Claude + Codex PostToolUse).
# Why:  keeps format-changed.sh protocol-agnostic. Claude PostToolUse supplies
#       tool_input.file_path; Codex apply_patch does not (it carries
#       tool_input.command instead) — no file_path means a clean no-op, so
#       Codex format-on-edit is dormant by design and validate enforces
#       formatting there.
set -uo pipefail
file=$(python3 -c "import json,sys
try: print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))
except Exception: print('')" 2>/dev/null)
[ -n "$file" ] || exit 0
exec bash "$(dirname "$0")/format-changed.sh" "$file"
