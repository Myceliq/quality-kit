#!/usr/bin/env bash
# What: CI drift gate — verify a stamped repo still matches the kit at its pin.
# Where: quality-kit/bin; invoked by each repo's quality.yml with KIT_DIR set.
# Why:  local edits stay free; merge is where weakening gets caught. Every
#       failure names its remedy so a repair-loop agent can self-correct.
set -euo pipefail
RATCHET=0 TARGET="."
while [ $# -gt 0 ]; do case "$1" in
  --ratchet) RATCHET=1; shift ;;
  -*)        echo "unknown flag $1 (usage: check-drift.sh <repo> [--ratchet])" >&2; exit 64 ;;
  *)         TARGET="$1"; shift ;;
esac; done
REPO="$(cd "$TARGET" && pwd)"
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
  # ruff.toml is rendered, not copied — compare against a fresh render of this
  # repo's own declared overrides, so a hand-edited rule list is still caught.
  RENDERED="$(mktemp)"
  bash "$KIT/bin/render-ruff.sh" "$REPO" > "$RENDERED"
  cmp -s "$RENDERED" "$REPO/ruff.toml" \
    || err "ruff.toml does not match a fresh render of .quality-kit.json — re-stamp, or revert the hand edit; rule overrides belong in .quality-kit.json"
  rm -f "$RENDERED"
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

def check_overrides():
    # Repo-owned rule overrides are sanctioned divergence, so their SHAPE is the
    # only thing standing between "declared, diff-visible, ratcheted" and "free
    # weakening". This runs on every profile and needs no toolchain — the count
    # ratchet (which does) is a separate --ratchet pass.
    qk = json.load(open(os.path.join(repo, ".quality-kit.json")))
    ov = qk.get("ruleOverrides", {"burnDown": {}, "permanent": {}})
    if not isinstance(ov, dict):
        err("ruleOverrides must be an object with burnDown/permanent — re-stamp to restore the default shape")
        return
    burn, perm = ov.get("burnDown", {}), ov.get("permanent", {})
    if not isinstance(burn, dict) or not isinstance(perm, dict):
        err("ruleOverrides.burnDown and ruleOverrides.permanent must both be objects — re-stamp to restore the default shape")
        return
    for rule, count in burn.items():
        # bool is an int subclass in python — exclude it explicitly, or
        # {"rule": true} would sail through as count 1
        if isinstance(count, bool) or not isinstance(count, int) or count < 1:
            err(f"ruleOverrides.burnDown[{rule}] must be a positive integer violation count (got {count!r}) — fix the count, or remove the entry if the burn-down is complete")
    for rule, spec in perm.items():
        if not isinstance(spec, dict):
            err(f"ruleOverrides.permanent[{rule}] must be an object with level and why — see quality-kit/README.md")
            continue
        allowed = ("off",) if profile == "python" else ("off", "warn")
        if spec.get("level") not in allowed:
            err(f"ruleOverrides.permanent[{rule}].level must be one of {list(allowed)} (got {spec.get('level')!r}) — ruff has no warn severity, so the python profile accepts off only")
        if not str(spec.get("why", "")).strip():
            err(f"ruleOverrides.permanent[{rule}] needs a non-empty why — a permanent divergence is a judgment call and must state its reason")
    for rule in set(burn) & set(perm):
        err(f"rule {rule} is in both burnDown and permanent — pick one: burn it down, or justify it permanently")
    ign = qk.get("ignoreOverrides", [])
    if not isinstance(ign, list) or any(not isinstance(g, str) for g in ign):
        err("ignoreOverrides must be a list of glob strings — fix .quality-kit.json")

def main():
    check_overrides()
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

if [ "$RATCHET" = 1 ]; then
  # The counting pass. Needs the repo's linter, so quality.yml runs it after
  # Install while the static gate above runs before it (cheap-first).
  BURN="$(python3 -c "
import json,sys
print(json.dumps((json.load(open(sys.argv[1])).get('ruleOverrides') or {}).get('burnDown') or {}))" "$QK")"
  if [ "$BURN" != "{}" ]; then
    # Toolchain check FIRST and loudly. baseline-rules.sh returns {} when the
    # linter is missing, which is indistinguishable from "zero violations" — and
    # zero would make every entry report "burn-down complete, remove it". A
    # missing toolchain must fail the gate, never quietly rewrite the burn-down.
    TOOLING_OK=1
    if [ "$PROFILE" = python ]; then
      command -v ruff >/dev/null 2>&1 || command -v uvx >/dev/null 2>&1 || TOOLING_OK=0
      [ "$TOOLING_OK" = 1 ] || err "ratchet needs ruff on PATH to count burn-down violations — install ruff in the CI job before this step"
    else
      [ -x "$REPO/node_modules/.bin/oxlint" ] || TOOLING_OK=0
      [ "$TOOLING_OK" = 1 ] || err "ratchet needs the repo's node_modules — run it after the Install step"
    fi
    if [ "$TOOLING_OK" = 1 ]; then
      # Counting and rule-id normalization live in baseline-rules.sh — the same
      # code that seeded these numbers must be the code that re-counts them, or
      # the two can disagree about what a rule is called and the ratchet silently
      # compares nothing. --select re-enables the rules the python profile
      # extend-ignore's; it is a no-op on TS, where they sit at warn already.
      SEL="$(python3 -c "
import json,sys; print(','.join(sorted(json.loads(sys.argv[1]))))" "$BURN")"
      # assign-then-fallback: baseline-rules.sh prints {} to stdout AND exits
      # non-zero on a linter failure. `$(cmd || echo '{}')` would capture BOTH
      # {}s (the printed one plus echo's) into "{}\n{}", which is invalid JSON.
      ACTUAL="$(bash "$KIT/bin/baseline-rules.sh" "$REPO" --select "$SEL" 2>/dev/null)" || ACTUAL='{}'
      python3 - "$BURN" "$ACTUAL" <<'PY' || fail=1
import json, sys
burn, actual = json.loads(sys.argv[1]), json.loads(sys.argv[2])
rc = 0
for rule, allowed in sorted(burn.items()):
    got = actual.get(rule, 0)
    if got > allowed:
        rc = 1
        print(f"DRIFT: burn-down regressed: {rule} {got} > recorded {allowed} — fix the new violations, or bump the count in .quality-kit.json in this PR with justification", file=sys.stderr)
    elif got == 0:
        rc = 1
        print(f"DRIFT: burn-down complete for {rule} — remove the entry from .quality-kit.json ruleOverrides.burnDown", file=sys.stderr)
sys.exit(rc)
PY
    fi
  fi
fi

[ "$fail" = 0 ] && { echo "drift gate clean (kit $KITV, profile $PROFILE)"; exit 0; }
exit 1
