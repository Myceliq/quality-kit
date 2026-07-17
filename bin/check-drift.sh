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
import json, os, sys
kit, repo, profile = sys.argv[1:4]
rc = 0
def err(m):
    global rc; rc = 1; print(f"DRIFT: {m}", file=sys.stderr)

def _scan_outside_strings(s, on_char):
    # Char-by-char pass tracking JSON string state (double quotes, backslash
    # escapes); everything inside a string literal is copied verbatim. This
    # is what stops a decoy payload like {"_a":"/*", ...,"_b":"*/"} — a real
    # comment marker split across two separate string VALUES — from being
    # misread as an actual comment span: a blind whole-file regex would
    # delete everything between the two string literals (hiding whatever
    # sits between them from this gate) while tsc's own string-aware parser
    # still honors it. on_char(out, s, i, n) handles one char outside a
    # string and returns the next index; it must append to out itself.
    out, i, n, in_str, esc = [], 0, len(s), False, False
    while i < n:
        c = s[i]
        if in_str:
            out.append(c)
            if esc: esc = False
            elif c == "\\": esc = True
            elif c == '"': in_str = False
            i += 1
        elif c == '"':
            in_str = True; out.append(c); i += 1
        else:
            i = on_char(out, s, i, n)
    return "".join(out)

def _drop_comment(out, s, i, n):
    if s[i:i+2] == "//":
        j = s.find("\n", i); return n if j == -1 else j
    if s[i:i+2] == "/*":
        j = s.find("*/", i + 2); return n if j == -1 else j + 2
    out.append(s[i]); return i + 1

def _drop_trailing_comma(out, s, i, n):
    if s[i] == ",":
        j = i + 1
        while j < n and s[j] in " \t\r\n": j += 1
        if j < n and s[j] in "}]":
            return i + 1  # drop the comma itself
    out.append(s[i]); return i + 1

def jsonc(p):  # tolerate // and /* */ comments + trailing commas (tsconfig style)
    s = open(p).read()
    s = _scan_outside_strings(s, _drop_comment)
    s = _scan_outside_strings(s, _drop_trailing_comma)
    return json.loads(s)

def main():
    if profile != "python":
        pkg = json.load(open(os.path.join(repo, "package.json")))
        canon = json.load(open(os.path.join(kit, f"ts/package-scripts.{profile}.json")))
        scripts = pkg.get("scripts", {})
        for k, v in canon.items():
            if scripts.get(k) != v:
                err(f"package.json scripts.{k} != kit canonical — restore: {v!r}")
        # profile also picks the oxlint/script preset among nextjs/vite/node —
        # a relabel within that family (e.g. nextjs -> node) isn't caught by
        # the byte-owned same() checks since they'd just compare against the
        # new profile's own files. Cross-check against what's actually
        # installed: next/react in package.json imply which presets are safe.
        deps = {**pkg.get("dependencies", {}), **pkg.get("devDependencies", {})}
        if "next" in deps and profile != "nextjs":
            err(f"profile {profile} inconsistent with dependencies (next present) — restore correct profile and re-stamp")
        elif "react" in deps and profile not in ("nextjs", "vite"):
            err(f"profile {profile} inconsistent with dependencies (react present) — restore correct profile and re-stamp")
        ts = jsonc(os.path.join(repo, "tsconfig.json"))
        ext = ts.get("extends", "")
        # exact match required, and it must be the LAST entry in an array —
        # TS applies extends left-to-right with later entries winning, so
        # quality-last is what makes its strict flags actually govern; a
        # substring match would let ./evil.json trail it, or a decoy path
        # like ./sub/tsconfig.quality.json stand in for the real fragment.
        last = ext if isinstance(ext, str) else (ext[-1] if ext else None)
        if last != "./tsconfig.quality.json":
            err("tsconfig extends must end with ./tsconfig.quality.json (exact entry, last position)")
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

try:
    main()
except Exception as e:
    # remedy-naming contract must hold even on crash paths — no bare
    # tracebacks out of a gate that's supposed to always say what to do.
    print(f"DRIFT: internal gate error ({type(e).__name__}) — fix the malformed file it names or re-stamp", file=sys.stderr)
    sys.exit(1)
sys.exit(rc)
PY

[ "$fail" = 0 ] && { echo "drift gate clean (kit $KITV, profile $PROFILE)"; exit 0; }
exit 1
