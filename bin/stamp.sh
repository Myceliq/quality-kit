#!/usr/bin/env bash
# What: stamp (or update) the quality-kit standard into a target repo.
# Where: this kit's bin/; run from a checkout of it against any fleet repo.
# Why:  one write path for the fleet standard — byte-owned files are copied,
#       shared files (package.json, tsconfig, AGENTS.md, .claude/settings.json)
#       are merged non-destructively; a manifest makes local edits detectable.
set -euo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="" PROFILE="" FORCE=0
while [ $# -gt 0 ]; do case "$1" in
  --profile) PROFILE="${2:?}"; shift 2 ;;
  --force)   FORCE=1; shift ;;
  -*)        echo "unknown flag $1" >&2; exit 64 ;;
  *)         REPO="$1"; shift ;;
esac; done
[ -n "$REPO" ] && [ -d "$REPO" ] || { echo "usage: stamp.sh <repo> --profile <nextjs|vite|node|python> [--force]" >&2; exit 64; }
case "$PROFILE" in nextjs|vite|node|python) ;; *) echo "unknown profile: $PROFILE" >&2; exit 64 ;; esac
REPO="$(cd "$REPO" && pwd)"
VERSION="$(cat "$KIT/VERSION")"

# refuse to clobber locally-modified stamped files unless --force
# Scope: the manifest guards BYTE-OWNED files only. Merged files
# (package.json, tsconfig.json, AGENTS.md, .claude/settings.json) are
# deliberately outside it: re-stamp is canonical-wins on kit-owned keys,
# and check-drift.sh rule-checks them in CI — the unforgeable layer.
if [ -f "$REPO/.quality/manifest.sha256" ] && [ "$FORCE" -ne 1 ]; then
  if ! (cd "$REPO" && sha256sum --check --quiet .quality/manifest.sha256 2>/dev/null); then
    echo "stamped files modified locally — inspect the diff, then rerun with --force" >&2
    exit 65
  fi
fi

mkdir -p "$REPO/.quality" "$REPO/.github/workflows" "$REPO/.claude" "$REPO/.codex"
STAMPED=()
put() { install -m "$2" "$KIT/$1" "$REPO/$3"; STAMPED+=("$3"); }

put hooks/format-changed.sh         755 .quality/format-changed.sh
put hooks/format-changed-adapter.sh 755 .quality/format-changed-adapter.sh
put hooks/stop-validate.sh          755 .quality/stop-validate.sh
put hooks/codex-hooks.json          644 .codex/hooks.json

RUNNER=npm
if [ "$PROFILE" = python ]; then
  RUNNER=make
  # ruff.toml is rendered (not copied) once .quality-kit.json exists — see below
  STAMPED+=(ruff.toml)
  put py/pyrightconfig.json 644 pyrightconfig.json
  put py/Makefile.quality  644 Makefile.quality
  touch "$REPO/Makefile"
  grep -q '^include Makefile.quality$' "$REPO/Makefile" || printf '\ninclude Makefile.quality\n' >> "$REPO/Makefile"
else
  put "ts/oxlint.config.$PROFILE.ts" 644 oxlint.config.ts
  put ts/oxfmt.config.ts             644 oxfmt.config.ts
  put ts/tsconfig.strict.json        644 tsconfig.quality.json
  put ts/quality.yml                 644 .github/workflows/quality.yml
fi

# python3 stdlib merges for shared files
python3 - "$KIT" "$REPO" "$PROFILE" "$VERSION" "$RUNNER" <<'PY'
import json, os, sys
kit, repo, profile, version, runner = sys.argv[1:6]
j = lambda p: json.load(open(p)) if os.path.exists(p) else {}
def w(p, d): open(p, "w").write(json.dumps(d, indent=2) + "\n")

# .quality-kit.json — the stamper owns version/profile/runner; every other key
# is repo-owned sanctioned variation (pendingFlags, ruleOverrides,
# ignoreOverrides) and must survive a re-stamp byte-exact. A re-stamp that
# silently reset a burn-down count would erase the ratchet's memory.
qk_path = os.path.join(repo, ".quality-kit.json")
prev = j(qk_path)
# start from the full previous object (preserves any top-level key the kit
# doesn't know about yet, same preserve-unknown idiom as the package.json/
# tsconfig/settings merges below) and only overlay what the stamper owns
overrides = dict(prev.get("ruleOverrides") or {})
overrides.setdefault("burnDown", {})
overrides.setdefault("permanent", {})
qk = dict(prev)
qk.update({
    "version": version, "profile": profile, "runner": runner,
    "pendingFlags": prev.get("pendingFlags", []),
    "ruleOverrides": overrides,
    "ignoreOverrides": prev.get("ignoreOverrides", []),
})
w(qk_path, qk)

if profile != "python":
    # package.json: canonical scripts win; other scripts and fields preserved
    pkg_path = os.path.join(repo, "package.json")
    pkg = j(pkg_path) or {"name": os.path.basename(repo), "private": True}
    pkg.setdefault("scripts", {}).update(j(os.path.join(kit, f"ts/package-scripts.{profile}.json")))
    dd = pkg.setdefault("devDependencies", {})
    dd.update(j(os.path.join(kit, "ts/pins.json")))
    # engines: the pinned toolchain floors Node at 22.12.0 (ultracite pulls
    # commander@15 at a flat >=22.12.0), and check-drift.sh now enforces that
    # floor — so the stamper writes it, or every fresh stamp would fail the
    # kit's own new gate. setdefault, not update: unlike scripts, this key is a
    # repo-owned ceiling as much as a floor. A repo declaring a STRICTER
    # engines.node (">=24") is making a real decision that canonical-wins would
    # silently undo; a repo declaring a WEAKER one keeps it and the drift gate
    # names the fix. Either way the stamper never lowers an existing floor.
    # npm requires engines to be an OBJECT. A non-object one is malformed, has
    # no key to preserve, and would make setdefault raise on a str — crashing
    # the stamper on a repo it is supposed to repair. Replace it: the change is
    # diff-visible in the stamp PR, which is where it should be argued.
    eng = pkg.get("engines")
    if not isinstance(eng, dict):
        eng = pkg["engines"] = {}
    for k, v in j(os.path.join(kit, "ts/engines.json")).items():
        eng.setdefault(k, v)
    w(pkg_path, pkg)
    # tsconfig.json: point extends at the stamped fragment, preserving any
    # pre-existing chain (TS 5+ array form, quality fragment last so its
    # strict flags still govern)
    ts_path = os.path.join(repo, "tsconfig.json")
    ts = j(ts_path)
    prev = ts.get("extends")
    if prev and prev != "./tsconfig.quality.json":
        prevs = prev if isinstance(prev, list) else [prev]
        prevs = [p for p in prevs if p != "./tsconfig.quality.json"]
        ts["extends"] = prevs + ["./tsconfig.quality.json"]
    else:
        ts["extends"] = "./tsconfig.quality.json"
    w(ts_path, ts)

# .claude/settings.json: deep-merge the hooks fragment (kit entries replace
# same-event entries whose command mentions .quality/, others preserved)
cs_path = os.path.join(repo, ".claude/settings.json")
cs = j(cs_path)
frag = j(os.path.join(kit, "hooks/claude-settings.json"))
hooks = cs.setdefault("hooks", {})
for event, entries in frag["hooks"].items():
    kept = [e for e in hooks.get(event, [])
            if not any(".quality/" in h.get("command", "") for h in e.get("hooks", []))]
    hooks[event] = kept + entries
w(cs_path, cs)

# AGENTS.md: replace/append the marker-delimited section
qm = open(os.path.join(kit, "agents/QUALITY.md")).read()
am_path = os.path.join(repo, "AGENTS.md")
am = open(am_path).read() if os.path.exists(am_path) else ""
b, e = "<!-- quality-kit:begin -->", "<!-- quality-kit:end -->"
if b in am and e in am:
    am = am[: am.index(b)] + qm + am[am.index(e) + len(e):].lstrip("\n")
else:
    am = (am.rstrip() + "\n\n" if am.strip() else "") + qm
open(am_path, "w").write(am if am.endswith("\n") else am + "\n")
PY

# Burn-down baseline: generate from a real lint run whenever burnDown is EMPTY
# — not literally "first stamp". stamp.sh adds oxlint/ruff to the repo's own
# deps above, so on a genuine first stamp the linter usually isn't installed
# yet and this is a no-op (see the else branch). The real seed happens on
# whichever later re-stamp runs after npm ci, which still sees burnDown=={}.
# Once ANY rule is seeded this block never runs again on that repo — a
# re-stamp must not silently absorb violations added since, same contract as
# the suppression baseline below. stamp.sh stays offline and deterministic:
# when the toolchain is absent this is a no-op that names the follow-up command.
FIRST_BURNDOWN="$(python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
print('1' if not (d.get('ruleOverrides') or {}).get('burnDown') else '0')" "$REPO/.quality-kit.json")"
if [ "$FIRST_BURNDOWN" = 1 ]; then
  # ponytail: baseline-rules.sh echoes its own "{}" to stdout before a non-zero
  # exit (missing/crashed linter); `cmd || echo` would append a second "{}"
  # onto that captured output instead of replacing it. Assign-then-fallback
  # keeps the failure path a clean "{}" instead of corrupt concatenated JSON.
  # The rc is captured separately so the toolchain-present-but-zero-violations
  # case (exit 0, "{}") isn't misreported as "toolchain absent".
  BR_RC=0
  BURN="$(bash "$KIT/bin/baseline-rules.sh" "$REPO" 2>/dev/null)" || BR_RC=$?
  if [ "$BURN" != "{}" ]; then
    python3 - "$REPO/.quality-kit.json" "$BURN" <<'PY'
import json, sys
path, burn = sys.argv[1], json.loads(sys.argv[2])
d = json.load(open(path))
d["ruleOverrides"]["burnDown"] = burn
open(path, "w").write(json.dumps(d, indent=2) + "\n")
PY
    echo "→ seeded ruleOverrides.burnDown with $(python3 -c "import json,sys;print(len(json.loads(sys.argv[1])))" "$BURN") rules from a lint run"
  elif [ "$BR_RC" = 0 ]; then
    echo "→ no burn-down needed — the linter reported zero violations"
  else
    echo "→ toolchain not ready (baseline-rules.sh exit $BR_RC) — after install, seed the burn-down: quality-kit/bin/baseline-rules.sh $REPO"
  fi
fi

# ruff.toml is a rendered file: kit base + this repo's declared overrides.
# ORDERING: this must be the LAST thing that touches .quality-kit.json's
# override keys before the manifest is hashed — it reads them. Task 6 inserts
# burn-down seeding ABOVE this block for exactly that reason; a render that ran
# first would omit the freshly seeded rules, leaving the repo red on day one and
# permanently mismatched against a fresh render in the drift gate.
if [ "$PROFILE" = python ]; then
  bash "$KIT/bin/render-ruff.sh" "$REPO" > "$REPO/ruff.toml"
  chmod 644 "$REPO/ruff.toml"
fi

# suppression baseline: initialize from current repo state on first stamp only
# (a re-stamp must not silently absorb suppressions added since — that is the
# drift gate's job to reject)
BASE="$REPO/.quality/suppression-baseline.json"
[ -f "$BASE" ] || bash "$KIT/bin/count-suppressions.sh" "$REPO" > "$BASE"
STAMPED+=(.quality/suppression-baseline.json)

# manifest over byte-owned files (merged files are rule-checked by drift, not hashed)
(cd "$REPO" && sha256sum "${STAMPED[@]}" > .quality/manifest.sha256)
echo "stamped $REPO (profile=$PROFILE, kit=$VERSION)"
# Point the operator at the blocking gotchas before they try to commit — most
# stamp PRs stall on one of these (npm ci reconcile, .claude gitignore, the
# first-commit hook bootstrap, protected-path override).
echo "→ before committing: read 'Stamping a repo — known gotchas' in quality-kit/README.md"
