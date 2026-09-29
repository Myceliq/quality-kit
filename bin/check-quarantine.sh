#!/usr/bin/env bash
# What: testQuarantine schema check (--static) and enforcement pass (--run).
# Where: quality-kit/bin; called by check-drift.sh — --static on every run,
#        --run in its place under `check-drift.sh --quarantine`.
# Why:  a quarantined test is a sanctioned red, so it must stay bounded: every
#       entry carries an expiry and a reason, an expired or stale entry refuses,
#       and a test run whose report cannot be read never reads as clean.
set -euo pipefail
MODE="" TARGET=""
while [ $# -gt 0 ]; do case "$1" in
  --static) MODE=static; shift ;;
  --run)    MODE=run; shift ;;
  -*)       echo "unknown flag $1 (usage: check-quarantine.sh <repo> --static|--run)" >&2; exit 64 ;;
  *)        TARGET="$1"; shift ;;
esac; done
[ -n "$MODE" ] && [ -n "$TARGET" ] || { echo "usage: check-quarantine.sh <repo> --static|--run" >&2; exit 64; }
REPO="$(cd "$TARGET" && pwd)"

python3 - "$MODE" "$REPO" <<'PY'
import datetime, json, os, re, shutil, subprocess, sys, tempfile
import xml.etree.ElementTree as ET
mode, repo = sys.argv[1:3]
rc = 0
def err(m):
    global rc; rc = 1; print(f"DRIFT: {m}", file=sys.stderr)

DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

def _date(v):
    # A real calendar date or None. The regex pins the exact YYYY-MM-DD spelling
    # (fromisoformat also takes 20261231 on newer pythons); strptime then refuses
    # dates that do not exist, like 2026-02-30.
    if not isinstance(v, str) or not DATE_RE.match(v):
        return None
    try:
        return datetime.datetime.strptime(v, "%Y-%m-%d").date()
    except ValueError:
        return None

def check_shape(q):
    # Same posture as check_overrides() in check-drift.sh: the shape is what keeps
    # "declared, bounded, reasoned" from being a free pass, so it is refused
    # without a toolchain, before anything runs.
    if not isinstance(q, dict):
        err("testQuarantine must be an object with command and entries — see quality-kit/README.md")
        return
    cmd = q.get("command")
    if not isinstance(cmd, str) or not cmd.strip():
        err(f"testQuarantine.command must be a non-empty shell command that runs the tests and writes a JUnit XML report to $QUALITY_KIT_JUNIT (got {cmd!r})")
    entries = q.get("entries")
    if not isinstance(entries, list):
        err(f"testQuarantine.entries must be an array of {{test, expires, reason}} objects (got {type(entries).__name__}) — use [] for no quarantined tests")
        return
    seen = set()
    for i, e in enumerate(entries):
        if not isinstance(e, dict):
            err(f"testQuarantine.entries[{i}] must be an object with test, expires and reason")
            continue
        test = e.get("test")
        if not isinstance(test, str) or not test.strip():
            err(f"testQuarantine.entries[{i}] needs a non-empty test id, written <classname>::<name> as the JUnit report names it")
            continue
        if test in seen:
            err(f"testQuarantine entry {test} is declared twice — keep one entry per test")
        seen.add(test)
        if _date(e.get("expires")) is None:
            err(f"testQuarantine entry {test} needs expires as a real calendar date YYYY-MM-DD (got {e.get('expires')!r}) — every quarantine is bounded")
        reason = e.get("reason")
        if not isinstance(reason, str) or not reason.strip():
            err(f"testQuarantine entry {test} needs a non-empty reason — a quarantined failure must say why it is tolerated")

def read_report(path):
    # {test id: failed|skipped|passed}, or None after naming why the report is
    # unusable. Every unusable shape refuses: an unread report must never read as
    # a clean run.
    if not os.path.isfile(path) or os.path.getsize(path) == 0:
        err("quarantine: testQuarantine.command wrote no JUnit report to $QUALITY_KIT_JUNIT — make the command write its JUnit XML there (e.g. vitest --reporter=junit --outputFile=\"$QUALITY_KIT_JUNIT\")")
        return None
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, ValueError) as e:
        err(f"quarantine: the JUnit report is not parseable XML ({e}) — fix the command's reporter output")
        return None
    rank = {"passed": 0, "skipped": 1, "failed": 2}
    out = {}
    for tc in root.iter("testcase"):
        tid = f"{tc.get('classname', '')}::{tc.get('name', '')}"
        tags = {child.tag for child in tc}
        st = "failed" if tags & {"failure", "error"} else "skipped" if "skipped" in tags else "passed"
        # a test reported twice (a retry) counts at its worst outcome
        if tid not in out or rank[st] > rank[out[tid]]:
            out[tid] = st
    if not out:
        err("quarantine: the JUnit report records no testcase — the command ran nothing, which is not a clean run; point it at the real suite")
        return None
    return out

def run(q):
    today = datetime.datetime.now(datetime.timezone.utc).date()   # = date -u +%F
    live = {}
    for e in q["entries"]:
        exp = _date(e["expires"])
        if exp < today:
            err(f"quarantine: entry {e['test']} expired on {e['expires']} — fix the test and remove the entry, or re-bound it with a new expires and reason in this PR")
        else:
            live[e["test"]] = e
    tmp = tempfile.mkdtemp()
    try:
        env = dict(os.environ, QUALITY_KIT_JUNIT=os.path.join(tmp, "junit.xml"))
        # stdout goes to stderr: the command's chatter must not mix into the
        # gate's own stdout verdict line
        code = subprocess.run(["bash", "-c", q["command"]], cwd=repo, env=env,
                              stdin=subprocess.DEVNULL, stdout=sys.stderr).returncode
        results = read_report(env["QUALITY_KIT_JUNIT"])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    if results is None:
        return
    failing = sorted(t for t, s in results.items() if s == "failed")
    if code != 0 and not failing:
        err(f"quarantine: testQuarantine.command failed (exit {code}) but its report records no failing testcase — the report does not describe this run; fix the command so its failures land in the report")
    for t in failing:
        if t in live:
            print(f"quarantined-skip: {t} — still failing, quarantined until {live[t]['expires']} ({live[t]['reason'].strip()})", file=sys.stderr)
        else:
            err(f"quarantine: {t} failed and has no live testQuarantine entry — fix the test, or quarantine it with an expires bound and a reason")
    for t in sorted(live):
        st = results.get(t)
        if st != "failed":
            why = "is absent from the report" if st is None else f"{st} in this run"
            err(f"quarantine: entry {t} is stale — the test {why}, so the quarantine hides nothing; remove the entry")

def main():
    qk = json.load(open(os.path.join(repo, ".quality-kit.json")))
    if "testQuarantine" not in qk:
        if mode == "run":
            print("quarantine: no testQuarantine declared in .quality-kit.json — nothing to enforce", file=sys.stderr)
        return
    q = qk["testQuarantine"]
    check_shape(q)
    if mode == "run" and rc == 0:   # a malformed block never gets its command run
        run(q)

try:
    main()
except Exception as e:
    print(f"DRIFT: quarantine: internal gate error ({type(e).__name__}) — fix the malformed file it names or re-stamp", file=sys.stderr)
    sys.exit(1)
sys.exit(rc)
PY
