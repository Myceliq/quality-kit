#!/usr/bin/env bash
# What: tests for the testQuarantine schema (static pass) and the
#       check-drift.sh --quarantine enforcement pass. Where: quality-kit/bin.
# Why:  a quarantine is a sanctioned way to stop a red test blocking merges, so
#       every way it could outlive its reason — expired, stale, unread report —
#       must be a covered refusal here, not just the happy path.
set -euo pipefail
unset FACTORY_GATE   # same reason as check-drift.test.sh: an inherited gate flag changes the static pass
DIR="$(cd "$(dirname "$0")" && pwd)"
KITROOT="$(cd "$DIR/.." && pwd)"
CD="$DIR/check-drift.sh"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }

fresh() { # stamped nextjs fixture, built exactly as check-drift.test.sh's fresh()
  local r; r="$(mktemp -d)"
  (cd "$r" && git init -q && git config core.hooksPath /dev/null \
    && printf '{"name":"fix","dependencies":{"next":"^16.3.1"},"scripts":{"build":"true"}}' > package.json \
    && printf '{"lockfileVersion":3,"packages":{"node_modules/next":{"version":"16.3.1"}}}' > package-lock.json \
    && printf 'import { it } from "vitest";\nit("smoke", () => {});\n' > smoke.test.ts \
    && printf '{}' > tsconfig.json && git add -A && git -c user.name=ci -c user.email=ci@example.com commit -q -m init)
  bash "$DIR/stamp.sh" "$r" --profile nextjs >/dev/null
  echo "$r"
}
static() { KIT_DIR="$KITROOT" bash "$CD" "$1" 2>&1; }
quar()   { KIT_DIR="$KITROOT" bash "$CD" "$1" --quarantine 2>&1; }
# qset <repo> <json|DELETE> — replace the testQuarantine block
qset() { python3 -c "
import json,sys; p=sys.argv[1]; d=json.load(open(p))
if sys.argv[2] == 'DELETE': d.pop('testQuarantine', None)
else: d['testQuarantine'] = json.loads(sys.argv[2])
json.dump(d,open(p,'w'),indent=2)" "$1/.quality-kit.json" "$2"; }
# emit <repo> <xml> <rc> — emit.sh writes <xml> to $QUALITY_KIT_JUNIT, exits <rc>
emit() { printf 'printf %%s %q > "$QUALITY_KIT_JUNIT"\nexit %s\n' "$2" "$3" > "$1/emit.sh"; }
entry() { printf '{"test": "%s", "expires": "%s", "reason": "%s"}' "$1" "$2" "$3"; }
block() { printf '{"command": "bash emit.sh", "entries": [%s]}' "$1"; }
# drift_has <out> <needle>... — some DRIFT: line contains every needle
drift_has() { local l; l="$(echo "$1" | grep '^DRIFT:' || true)"; shift
  for n in "$@"; do l="$(echo "$l" | grep -F -- "$n" || true)"; done; [ -n "$l" ]; }
# line_has <out> <needle>... — some line contains every needle
line_has() { local l="$1"; shift
  for n in "$@"; do l="$(echo "$l" | grep -F -- "$n" || true)"; done; [ -n "$l" ]; }
check() { "$@" && ok "$T" || bad "$T" "$out"; }
refute() { "$@" && bad "$T" "$out" || ok "$T"; }

TWO='<testsuite name="suite"><testcase classname="suite" name="flaky"><failure message="boom"/></testcase><testcase classname="suite" name="steady"/></testsuite>'
THREE='<testsuite name="suite"><testcase classname="suite" name="flaky"><failure message="boom"/></testcase><testcase classname="suite" name="steady"/><testcase classname="suite" name="later"><skipped/></testcase></testsuite>'
LIVE="$(entry suite::flaky 2999-12-31 'races the clock')"

R="$(fresh)"
emit "$R" "$TWO" 1

# --- Requirement: schema (static pass, no flag) ---
qset "$R" "$(block "$LIVE")"
rc=0; out="$(static "$R")" || rc=$?
T="well-formed block: static gate exits 0"; check [ "$rc" = 0 ]
T="well-formed block: static gate says clean"; check line_has "$out" "drift gate clean"

before="$(python3 -c "import json,sys;print(json.dumps(json.load(open(sys.argv[1]))['testQuarantine'],sort_keys=True))" "$R/.quality-kit.json")"
bash "$DIR/stamp.sh" "$R" --profile nextjs >/dev/null
after="$(python3 -c "import json,sys;print(json.dumps(json.load(open(sys.argv[1])).get('testQuarantine'),sort_keys=True))" "$R/.quality-kit.json")"
out="$before / $after"; T="re-stamp preserves testQuarantine"; check [ "$before" = "$after" ]

qset "$R" "$(block "$(entry suite::flaky 2999-12-31 '   ')")"
rc=0; out="$(static "$R")" || rc=$?
T="blank reason refused"; check [ "$rc" = 1 ]
T="blank reason names the entry"; check drift_has "$out" testQuarantine suite::flaky

for exp in OMIT 2026-02-30 "next week"; do
  if [ "$exp" = OMIT ]; then e='{"test": "suite::flaky", "reason": "races the clock"}'
  else e="$(entry suite::flaky "$exp" 'races the clock')"; fi
  qset "$R" "$(block "$e")"
  rc=0; out="$(static "$R")" || rc=$?
  T="expires [$exp] refused"; check [ "$rc" = 1 ]
  T="expires [$exp] names the entry"; check drift_has "$out" testQuarantine suite::flaky
done

for cmd in OMIT '""'; do
  if [ "$cmd" = OMIT ]; then b="{\"entries\": [$LIVE]}"; else b="{\"command\": \"\", \"entries\": [$LIVE]}"; fi
  qset "$R" "$b"
  rc=0; out="$(static "$R")" || rc=$?
  T="command [$cmd] refused"; check [ "$rc" = 1 ]
  T="command [$cmd] names testQuarantine.command"; check drift_has "$out" testQuarantine.command
done

qset "$R" "$(block "$LIVE, $LIVE")"
rc=0; out="$(static "$R")" || rc=$?
T="duplicate test id refused"; check [ "$rc" = 1 ]
T="duplicate test id named"; check drift_has "$out" testQuarantine suite::flaky

for b in '[]' '"x"' '{"command": "bash emit.sh", "entries": {}}'; do
  qset "$R" "$b"
  rc=0; out="$(static "$R")" || rc=$?
  T="container $b refused"; check [ "$rc" = 1 ]
  T="container $b names testQuarantine"; check drift_has "$out" testQuarantine
  T="container $b does not traceback"; refute line_has "$out" Traceback
done

# the bound is date-only: a run-count key would read as enforced but never is
for k in runs maxRuns runCount; do
  qset "$R" "$(block "{\"test\": \"suite::flaky\", \"expires\": \"2999-12-31\", \"$k\": 3, \"reason\": \"races the clock\"}")"
  rc=0; out="$(static "$R")" || rc=$?
  T="entry key [$k] refused"; check [ "$rc" = 1 ]
  T="entry key [$k] named as unsupported run-count, asks for expires"; check drift_has "$out" "$k" suite::flaky run-count expires
done

for k in expiry until; do
  qset "$R" "$(block "{\"test\": \"suite::flaky\", \"expires\": \"2999-12-31\", \"$k\": \"2999-12-31\", \"reason\": \"races the clock\"}")"
  rc=0; out="$(static "$R")" || rc=$?
  T="entry key [$k] refused"; check [ "$rc" = 1 ]
  T="entry key [$k] named"; check drift_has "$out" "$k" suite::flaky
  T="entry key [$k] does not traceback"; refute line_has "$out" Traceback
  T="entry key [$k] is no internal gate error"; refute line_has "$out" "internal gate error"
done

qset "$R" "{\"command\": \"bash emit.sh\", \"entries\": [$LIVE], \"maxRuns\": 3}"
rc=0; out="$(static "$R")" || rc=$?
T="block key [maxRuns] refused"; check [ "$rc" = 1 ]
T="block key [maxRuns] named"; check drift_has "$out" testQuarantine maxRuns

qset "$R" '{"command": "bash emit.sh", "entries": {}, "owner": "x"}'
rc=0; out="$(static "$R")" || rc=$?
T="block key [owner] beside malformed entries refused"; check [ "$rc" = 1 ]
T="block key [owner] beside malformed entries named"; check drift_has "$out" testQuarantine owner
T="malformed entries still named beside block key"; check drift_has "$out" testQuarantine.entries

# --- Requirement: quarantined-skip ---
qset "$R" "$(block "$LIVE")"
rc=0; out="$(quar "$R")" || rc=$?
T="quarantined failing test: exit 0"; check [ "$rc" = 0 ]
T="quarantined failing test reads quarantined-skip"; check line_has "$out" quarantined-skip suite::flaky
T="quarantined failing test is not a DRIFT"; refute drift_has "$out" suite::flaky
T="quarantined failing test: gate clean"; check line_has "$out" "drift gate clean"
T="future bound: nothing reads expired"; refute line_has "$out" expired

qset "$R" "$(block "")"
rc=0; out="$(quar "$R")" || rc=$?
T="removed entry exposes failure: exit 1"; check [ "$rc" = 1 ]
T="removed entry exposes failure: named"; check drift_has "$out" suite::flaky failed
T="removed entry: no quarantined-skip"; refute line_has "$out" quarantined-skip

emit "$R" '<testsuites><testsuite name="suite"><testcase classname="suite" name="flaky"><error message="boom"/></testcase><testcase classname="suite" name="steady"/></testsuite></testsuites>' 1
qset "$R" "$(block "$LIVE")"
rc=0; out="$(quar "$R")" || rc=$?
T="error + testsuites wrapper: exit 0"; check [ "$rc" = 0 ]
T="error + testsuites wrapper: quarantined-skip"; check line_has "$out" quarantined-skip suite::flaky

emit "$R" "$THREE" 1
rc=0; out="$(quar "$R")" || rc=$?
T="non-quarantined skipped test: exit 0"; check [ "$rc" = 0 ]
T="non-quarantined skipped test is no DRIFT"; refute drift_has "$out" suite::later

emit "$R" "$TWO" 1
qset "$R" "{\"command\": \"touch cwd-marker && bash emit.sh\", \"entries\": [$LIVE]}"
rm -f "$R/cwd-marker"; ELSEWHERE="$(mktemp -d)"
(cd "$ELSEWHERE" && KIT_DIR="$KITROOT" bash "$CD" "$R" --quarantine >/dev/null 2>&1 || true)
out="$(ls -A "$R")"; T="command runs from the repo root"; check [ -f "$R/cwd-marker" ]
T="command does not run from the caller's cwd"; refute [ -e "$ELSEWHERE/cwd-marker" ]
rm -f "$R/cwd-marker"

# --- Requirement: expiry ---
qset "$R" "$(block "$(entry suite::flaky 2000-01-01 'races the clock')")"
rc=0; out="$(quar "$R")" || rc=$?
T="past bound: exit 1"; check [ "$rc" = 1 ]
T="past bound: named expired"; check drift_has "$out" expired suite::flaky

qset "$R" "$(block "$(entry suite::flaky "$(date -u +%F)" 'races the clock')")"
rc=0; out="$(quar "$R")" || rc=$?
T="bound = today: exit 0"; check [ "$rc" = 0 ]
T="bound = today: nothing reads expired"; refute line_has "$out" expired

# --- Requirement: stale ---
qset "$R" "$(block "$(entry suite::steady 2999-12-31 'was flaky')")"
rc=0; out="$(quar "$R")" || rc=$?
T="passing test entry: exit 1"; check [ "$rc" = 1 ]
T="passing test entry: named stale"; check drift_has "$out" stale suite::steady
T="passing test entry: not quarantined-skip"; refute line_has "$out" quarantined-skip suite::steady

qset "$R" "$(block "$LIVE, $(entry suite::gone 2999-12-31 'was flaky')")"
rc=0; out="$(quar "$R")" || rc=$?
T="absent test entry: exit 1"; check [ "$rc" = 1 ]
T="absent test entry: named"; check drift_has "$out" suite::gone

emit "$R" "$THREE" 1
qset "$R" "$(block "$LIVE, $(entry suite::later 2999-12-31 'was flaky')")"
rc=0; out="$(quar "$R")" || rc=$?
T="skipped test entry: exit 1"; check [ "$rc" = 1 ]
T="skipped test entry: named"; check drift_has "$out" suite::later
T="skipped test entry: not quarantined-skip"; refute line_has "$out" quarantined-skip suite::later

# --- Requirement: fail closed ---
qset "$R" '{"command": "true", "entries": []}'
rc=0; out="$(quar "$R")" || rc=$?
T="no report: exit 1"; check [ "$rc" = 1 ]
T="no report: named"; check drift_has "$out" report

qset "$R" "$(block "")"
emit "$R" '<testsuite name="suite"></testsuite>' 0
rc=0; out="$(quar "$R")" || rc=$?
T="zero testcases: exit 1"; check [ "$rc" = 1 ]
T="zero testcases: named"; check drift_has "$out" report

emit "$R" 'not xml <' 1
rc=0; out="$(quar "$R")" || rc=$?
T="unparseable report: exit 1"; check [ "$rc" = 1 ]
T="unparseable report: named"; check drift_has "$out" report
T="unparseable report: no traceback"; refute line_has "$out" Traceback

emit "$R" '<testsuite name="suite"><testcase classname="suite" name="steady"/></testsuite>' 3
rc=0; out="$(quar "$R")" || rc=$?
T="non-zero exit, no failing testcase: exit 1"; check [ "$rc" = 1 ]
T="non-zero exit, no failing testcase: named"; check drift_has "$out" "exit 3"

rm -f "$R/ran-marker"
qset "$R" '{"command": "touch ran-marker", "entries": {}}'
rc=0; out="$(quar "$R")" || rc=$?
T="malformed block under --quarantine: exit 1"; check [ "$rc" = 1 ]
T="malformed block under --quarantine: named"; check drift_has "$out" testQuarantine
T="malformed block: command never ran"; refute [ -e "$R/ran-marker" ]
T="malformed block under --quarantine: no traceback"; refute line_has "$out" Traceback

rm -f "$R/ran-marker"
qset "$R" '{"command": "touch ran-marker", "entries": [{"test": "suite::flaky", "expires": "2999-12-31", "runs": 3, "reason": "races the clock"}]}'
rc=0; out="$(quar "$R")" || rc=$?
T="run-count entry under --quarantine: exit 1"; check [ "$rc" = 1 ]
T="run-count entry under --quarantine: named"; check drift_has "$out" runs
T="run-count entry: command never ran"; refute [ -e "$R/ran-marker" ]

rm -f "$R/ran-marker"
qset "$R" '{"command": "touch ran-marker", "entries": [], "owner": "x"}'
rc=0; out="$(quar "$R")" || rc=$?
T="block key under --quarantine: exit 1"; check [ "$rc" = 1 ]
T="block key under --quarantine: named"; check drift_has "$out" owner
T="block key: command never ran"; refute [ -e "$R/ran-marker" ]

# --- Requirement: no block declared ---
qset "$R" DELETE
rc=0; out="$(quar "$R")" || rc=$?
T="absent block: exit 0"; check [ "$rc" = 0 ]
T="absent block: named"; check line_has "$out" "no testQuarantine declared"
T="absent block: gate clean"; check line_has "$out" "drift gate clean"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
