#!/usr/bin/env bash
# What: hook-protocol shim — reads the tool-use JSON on stdin, formats the file.
# Where: stamped as .quality/format-changed-adapter.sh (Claude PostToolUse).
# Why:  keeps format-changed.sh protocol-agnostic. Claude PostToolUse supplies
#       tool_input.file_path; no file_path means a clean no-op. Codex's
#       apply_patch payload carries tool_input.command and no file_path, so
#       the kit wires no Codex formatter hook — validate enforces formatting
#       there.
set -uo pipefail
file=$(python3 -c "import json,sys
try: print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))
except Exception: print('')" 2>/dev/null)
[ -n "$file" ] || exit 0
exec bash "$(dirname "$0")/format-changed.sh" "$file"
