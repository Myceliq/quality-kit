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

# --- refuse a package manager this kit cannot generate working CI for (#7) ---
# What:  on TS profiles, detect the manager and stamp only npm.
# Where: before ANY file is written, so a refusal leaves no half-stamped repo.
# Why:   ts/quality.yml hardcodes `npm ci` and a `cache: 'npm'` key, and
#        check-drift's next floor reads package-lock.json and fails CLOSED without
#        one. Stamping a pnpm repo therefore SUCCEEDS, prints "stamped", and hands
#        back CI that cannot install plus a drift gate permanently red on a file the
#        repo will never have. An unsupported manager must not be able to produce a
#        green stamp.
#
#        Detection is from the LOCKFILE, because that is what CI installs and it is
#        the ground truth everywhere else in this kit. A declared `packageManager`
#        counts too — it is positive evidence even before a lockfile is committed.
#        Disagreement between them is ambiguous and refused rather than resolved:
#        guessing is how a repo gets CI for a manager it does not use.
#
#        No signal at all is deliberately NOT refused. Stamping before the first
#        install reconcile is an existing, working flow (README, "known gotchas"),
#        and refusing it would break re-stamps for the repos already on the kit.
#        This narrows the hole; full pnpm support is #7 proper.
#
#        python3 is a hard precondition, stated here rather than assumed. It was
#        always one — the manifest/package.json merges below are a python3 heredoc —
#        but only implicitly, so a box without it got a half-stamped repo and a crash
#        partway through. Detection must not be the one step that degrades quietly:
#        swallowing a missing interpreter would turn a declared pnpm repo back into a
#        silent npm stamp, which is the exact failure this guard exists to stop.
command -v python3 >/dev/null 2>&1 || {
  echo "python3 is required by stamp.sh (package-manager detection and the package.json merges)" >&2
  exit 78
}

if [ "$PROFILE" != python ]; then
  DETECTED="$(
    cd "$REPO"
    [ -f package-lock.json ] && echo npm
    [ -f pnpm-lock.yaml ]    && echo pnpm
    [ -f yarn.lock ]         && echo yarn
    { [ -f bun.lockb ] || [ -f bun.lock ]; } && echo bun
    if [ -f package.json ]; then
      python3 -c "
import json, re, sys
try:
    pm = json.load(open('package.json')).get('packageManager')
except Exception:
    sys.exit(0)
if isinstance(pm, str):
    m = re.match(r'([a-z]+)', pm.strip())
    if m and m.group(1) in ('npm', 'pnpm', 'yarn', 'bun'):
        print(m.group(1))
"
    fi
    true
  )"
  # xargs rather than grep -v + tr: `pipefail` is on, and a grep that matches nothing
  # exits 1, which under `set -e` aborts the stamp on exactly the common case — a repo
  # with no signals at all. xargs collapses the blanks and cannot fail on empty input.
  DETECTED="$(printf '%s\n' "$DETECTED" | sort -u | xargs)"
  case "$DETECTED" in
    ""|"npm") ;;
    *)
      echo "unsupported package manager: detected [$DETECTED]" >&2
      echo "This kit stamps npm only. .github/workflows/quality.yml runs 'npm ci' and" >&2
      echo "check-drift.sh verifies the next floor from package-lock.json, so stamping" >&2
      echo "this repo would produce CI that cannot install and a drift gate that is" >&2
      echo "permanently red on a file the repo will never have." >&2
      echo "Refusing rather than shipping broken CI. Tracking: Myceliq/quality-kit#7." >&2
      exit 78
      ;;
  esac
fi

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
# .codex/hooks.json is written like any other stamped file, but writing it does
# not arm it: Codex drops a project's hooks unless the project is trusted in the
# user's own config, and drops an unreviewed hook even in a trusted project —
# both silently. Say so here, because a stamp that looks complete is exactly
# when the operator stops checking. The kit does not touch the Codex config.
echo "→ .codex/hooks.json is stamped but INERT until Codex trusts this project AND the hooks are approved once — read 'The stamped Codex hooks' in quality-kit/README.md"
# The boundary belongs in the OUTPUT, not only in this comment: an operator told
# a control is off will look for the switch, and needs to know the kit did not
# flip it for them and will not.
echo "  (the kit does not read or write "'$CODEX_HOME'"/config.toml, default ~/.codex — granting trust is yours to do)"
