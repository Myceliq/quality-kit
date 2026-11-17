#!/usr/bin/env bash
# What: the burn-down ratchet — re-count every rule in .quality-kit.json
#       ruleOverrides.burnDown and fail when one grew past its recorded count or
#       reached zero (the entry must then be removed).
# Where: quality-kit/bin; stamped as .quality/ratchet.sh beside .quality/baseline-rules.sh.
#        Run by check-drift.sh --ratchet (CI) and by the canonical validate:fast (local).
# Why:  one implementation for both entry points (booking-platform #1005): a fix that
#       passed validate:fast used to go red only at CI's ratchet step. It finds
#       baseline-rules.sh next to itself, so the same file runs from the kit's bin/
#       and from a stamped repo's .quality/.
set -euo pipefail
[ $# = 1 ] || { echo "usage: ratchet.sh <repo>" >&2; exit 64; }
REPO="$(cd "$1" && pwd)"
BR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/baseline-rules.sh"
QK="$REPO/.quality-kit.json"
[ -f "$QK" ] || { echo "DRIFT: missing .quality-kit.json — run quality-kit/bin/stamp.sh" >&2; exit 66; }

# "<profile> <burnDown JSON>", one line. An unreadable marker exits 66 with a named
# DRIFT line rather than a traceback — and never reads as an empty burn-down.
read -r PROFILE BURN < <(python3 -c "
import json,sys
try:
    d = json.load(open(sys.argv[1]))
except ValueError:
    print('DRIFT: .quality-kit.json is not valid JSON — run quality-kit/bin/stamp.sh', file=sys.stderr); print('!'); sys.exit()
d = d if isinstance(d, dict) else {}
ov = d.get('ruleOverrides') or {}
ov = ov if isinstance(ov, dict) else {}
bd = ov.get('burnDown')
# Coerce a malformed (non-dict) burnDown to {} so the ratchet is a no-op on it:
# check-drift's static pass reports the shape error with its remedy, and a
# non-dict here would otherwise build a garbage --select and surface a
# misleading 'linter failed' DRIFT on top of the correct one.
print(d.get('profile') or '-', json.dumps(bd if isinstance(bd, dict) else {}, separators=(',', ':')))" "$QK")
[ "$PROFILE" != '!' ] || exit 66
# Nothing to count: pass instantly, no linter run.
[ "$BURN" != "{}" ] || { echo "ratchet: no burn-down entries"; exit 0; }

# Toolchain check FIRST and loudly. baseline-rules.sh returns {} when the
# linter is missing, which is indistinguishable from "zero violations" — and
# zero would make every entry report "burn-down complete, remove it". A
# missing toolchain must fail the gate, never quietly rewrite the burn-down.
if [ "$PROFILE" = python ]; then
  command -v ruff >/dev/null 2>&1 || command -v uvx >/dev/null 2>&1 \
    || { echo "DRIFT: ratchet needs ruff on PATH to count burn-down violations — install ruff in the CI job before this step" >&2; exit 1; }
else
  [ -x "$REPO/node_modules/.bin/oxlint" ] \
    || { echo "DRIFT: ratchet needs the repo's node_modules — run it after the Install step" >&2; exit 1; }
fi

# Counting and rule-id normalization live in baseline-rules.sh — the same
# code that seeded these numbers must be the code that re-counts them, or
# the two can disagree about what a rule is called and the ratchet silently
# compares nothing. --select re-enables the rules the python profile
# extend-ignore's; it is a no-op on TS, where they sit at warn already.
SEL="$(python3 -c "
import json,sys; print(','.join(sorted(json.loads(sys.argv[1]))))" "$BURN")"
# capture the rc without letting set -e abort on it: baseline-rules.sh
# exits non-zero (3 not installed, 4 crashed) and prints {} to stdout in
# both cases. A crash must not be read as "{}" == "all burn-down
# complete" — that would tell an automated repair-loop to delete the
# entire ledger over a transient linter crash.
# stderr is NOT discarded: only stdout is captured, so baseline-rules.sh's
# dirty-tree warning and the linter's own failure text land in the drift
# report beside the DRIFT line they explain, without touching ACTUAL.
BR_RC=0
ACTUAL="$(bash "$BR" "$REPO" --select "$SEL")" || BR_RC=$?
if [ "$BR_RC" != 0 ]; then
  echo "DRIFT: ratchet: the linter failed to run (baseline-rules.sh exit $BR_RC) — fix the linter/config and re-run; a crashed lint run must not be read as 'all burn-down complete'" >&2
  exit 1
fi
python3 - "$BURN" "$ACTUAL" <<'PY'
import json, sys
burn, actual = json.loads(sys.argv[1]), json.loads(sys.argv[2])
rc = 0
for rule, allowed in sorted(burn.items()):
    got = actual.get(rule, 0)
    if got > allowed:
        rc = 1
        print(f"DRIFT: burn-down regressed: {rule} {got} > recorded {allowed} — fix the new violations; a burn-down count never goes up", file=sys.stderr)
    elif got == 0:
        rc = 1
        print(f"DRIFT: burn-down complete for {rule} — remove the entry from .quality-kit.json ruleOverrides.burnDown", file=sys.stderr)
if rc == 0:
    print(f"ratchet: {len(burn)} burn-down entries within their recorded counts")
sys.exit(rc)
PY
