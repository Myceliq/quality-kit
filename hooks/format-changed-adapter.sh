#!/usr/bin/env bash
# What: hook-protocol shim — reads the tool-use JSON on stdin, formats the file.
# Where: stamped as .quality/format-changed-adapter.sh (Claude + Codex PostToolUse).
# Why:  keeps format-changed.sh protocol-agnostic; the JSON shape is the only
#       runtime-specific part and both runtimes use tool_input.file_path.
set -uo pipefail
file=$(python3 -c "import json,sys
try: print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))
except Exception: print('')" 2>/dev/null)
[ -n "$file" ] || exit 0
exec bash "$(dirname "$0")/format-changed.sh" "$file"
