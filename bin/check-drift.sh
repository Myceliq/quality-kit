#!/usr/bin/env bash
# What: CI drift gate — verify a stamped repo still matches the kit at its pin.
# Where: quality-kit/bin; invoked by each repo's quality.yml with KIT_DIR set.
# Why:  local edits stay free; merge is where weakening gets caught. Every
#       failure names its remedy so a repair-loop agent can self-correct.
set -euo pipefail
REPO="$(cd "${1:-.}" && pwd)"
KIT="${KIT_DIR:?set KIT_DIR to the kit checkout}"
fail=0
err() { echo "DRIFT: $*" >&2; fail=1; }

QK="$REPO/.quality-kit.json"
[ -f "$QK" ] || { echo "DRIFT: missing .quality-kit.json — run quality-kit/bin/stamp.sh" >&2; exit 66; }
PROFILE="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['profile'])" "$QK")"
PIN="$(python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['version'])" "$QK")"
KITV="$(cat "$KIT/VERSION")"
[ "$PIN" = "$KITV" ] || err "kit pin $PIN != checked-out kit $KITV — CI must check out tag quality-kit-v$PIN"

same() { cmp -s "$KIT/$1" "$REPO/$2" || err "$2 diverges from kit — restore it or change the kit and re-stamp; local edits to stamped files are not allowed"; }
same hooks/format-changed.sh         .quality/format-changed.sh
same hooks/format-changed-adapter.sh .quality/format-changed-adapter.sh
same hooks/stop-validate.sh          .quality/stop-validate.sh
same hooks/codex-hooks.json          .codex/hooks.json
# profile is repo-controlled (.quality-kit.json) — flipping it would let the
# checks below skip a whole category unless we confirm the *other* profile's
# byte-owned marker isn't still sitting there from the real stamp.
if [ "$PROFILE" = python ]; then
  [ -f "$REPO/.github/workflows/quality.yml" ] && err "profile=python but .github/workflows/quality.yml (ts-profile artifact) is present — profile field does not match the repo's actual stamped file set"
  same py/ruff.toml ruff.toml
  same py/pyrightconfig.json pyrightconfig.json
  same py/Makefile.quality Makefile.quality
  grep -q '^include Makefile.quality$' "$REPO/Makefile" 2>/dev/null \
    || err "root Makefile no longer includes Makefile.quality — restore the include line"
else
  [ -f "$REPO/Makefile.quality" ] && err "profile=$PROFILE but Makefile.quality (python-profile artifact) is present — profile field does not match the repo's actual stamped file set"
  same "ts/oxlint.config.$PROFILE.ts" oxlint.config.ts
  same ts/oxfmt.config.ts oxfmt.config.ts
  same ts/tsconfig.strict.json tsconfig.quality.json
  same ts/quality.yml .github/workflows/quality.yml
fi

python3 - "$KIT" "$REPO" "$PROFILE" <<'PY' || fail=1
import json, os, re, sys
kit, repo, profile = sys.argv[1:4]
rc = 0
def err(m):
    global rc; rc = 1; print(f"DRIFT: {m}", file=sys.stderr)
def jsonc(p):  # tolerate // and /* */ comments + trailing commas (tsconfig style)
    s = open(p).read()
    s = re.sub(r"/\*.*?\*/", "", s, flags=re.S)
    s = re.sub(r"//[^\n]*", "", s)
    return json.loads(re.sub(r",(\s*[}\]])", r"\1", s))

if profile != "python":
    canon = json.load(open(os.path.join(kit, f"ts/package-scripts.{profile}.json")))
    scripts = json.load(open(os.path.join(repo, "package.json"))).get("scripts", {})
    for k, v in canon.items():
        if scripts.get(k) != v:
            err(f"package.json scripts.{k} != kit canonical — restore: {v!r}")
    ts = jsonc(os.path.join(repo, "tsconfig.json"))
    ext = ts.get("extends", "")
    if "tsconfig.quality.json" not in (ext if isinstance(ext, str) else " ".join(ext)):
        err("tsconfig.json must extend ./tsconfig.quality.json")
    pending = json.load(open(os.path.join(repo, ".quality-kit.json"))).get("pendingFlags", [])
    protected = jsonc(os.path.join(kit, "ts/tsconfig.strict.json"))["compilerOptions"]
    for flag, want in protected.items():
        got = ts.get("compilerOptions", {}).get(flag, want)
        if got != want and flag not in pending:
            err(f"tsconfig relaxes protected flag {flag} — revert, or stage it via .quality-kit.json pendingFlags")

# the merged .claude/settings.json must still carry the kit's hook entries
# under the same event with the same behavior-defining fields (matcher +
# type/command). Extra metadata fields and repo-added entries are fine —
# checking whole-object equality would false-positive on benign schema
# evolution; checking command presence alone would miss matcher tampering.
cs_path = os.path.join(repo, ".claude/settings.json")
cs = json.load(open(cs_path)) if os.path.exists(cs_path) else {}
frag = json.load(open(os.path.join(kit, "hooks/claude-settings.json")))
for event, entries in frag["hooks"].items():
    for entry in entries:
        want = [(h.get("type"), h.get("command")) for h in entry["hooks"]]
        def covers(e):
            got = [(h.get("type"), h.get("command")) for h in e.get("hooks", [])]
            return e.get("matcher") == entry.get("matcher") and all(w in got for w in want)
        if not any(covers(e) for e in cs.get("hooks", {}).get(event, [])):
            err(f".claude/settings.json lost or altered the kit {event} hook — re-stamp to restore")

base = json.load(open(os.path.join(repo, ".quality/suppression-baseline.json")))
import subprocess
now = json.loads(subprocess.run(
    ["bash", os.path.join(kit, "bin/count-suppressions.sh"), repo],
    capture_output=True, text=True, check=True).stdout)
for k, allowed in base.items():
    if now.get(k, 0) > allowed:
        err(f"suppression budget exceeded: {k} {now[k]} > baseline {allowed} — remove them or bump .quality/suppression-baseline.json in this PR with justification")
sys.exit(rc)
PY

[ "$fail" = 0 ] && { echo "drift gate clean (kit $KITV, profile $PROFILE)"; exit 0; }
exit 1
