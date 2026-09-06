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

# --- pick the package manager, or refuse one the kit cannot serve (#7) -------
# What:  on TS profiles, resolve the manager and stamp its quality.yml variant.
# Where: before ANY file is written, so a refusal leaves no half-stamped repo.
# Why:   the stamped workflow hardcodes an install command and a setup-node cache
#        key, and check-drift's next floor reads a specific lockfile and fails
#        CLOSED without it. Get the manager wrong and the stamp SUCCEEDS, prints
#        "stamped", and hands back CI that cannot install plus a drift gate
#        permanently red on a file the repo will never have.
#
#        npm and pnpm are served (ts/quality.npm.yml, ts/quality.pnpm.yml).
#        yarn and bun are refused: a third and fourth lockfile parser costs a set
#        of edge cases each for zero adopters, and an unsupported manager must not
#        be able to produce a green stamp by being silently treated as npm.
#
#        Two managers detected is ambiguous and refused rather than resolved —
#        guessing is how a repo gets CI for a manager it does not use. Detection
#        itself lives in bin/detect-manager.sh, shared with check-drift.sh so the
#        writer and the gate cannot disagree about which manager a repo is on.
#
#        No signal at all is deliberately NOT refused, and defaults to npm.
#        Stamping before the first install reconcile is an existing, working flow
#        (README, "known gotchas"), and refusing it would break re-stamps for the
#        repos already on the kit.
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

MANAGER=npm
if [ "$PROFILE" != python ]; then
  DETECTED="$(bash "$KIT/bin/detect-manager.sh" "$REPO")"
  case "$DETECTED" in
    ""|"npm") MANAGER=npm ;;
    "pnpm")   MANAGER=pnpm ;;
    *)
      echo "unsupported package manager: detected [$DETECTED]" >&2
      echo "This kit stamps npm and pnpm, and only one of them per repo." >&2
      echo ".github/workflows/quality.yml runs that manager's install command and" >&2
      echo "check-drift.sh verifies the next floor from that manager's lockfile, so" >&2
      echo "stamping this repo would produce CI that cannot install and a drift gate" >&2
      echo "that is permanently red on a file the repo will never have." >&2
      echo "Two managers detected means the signals disagree — delete the lockfile (or" >&2
      echo "the packageManager field) for the manager this repo does not install." >&2
      echo "An 'unsupported:<name>' entry is a packageManager naming a manager this kit" >&2
      echo "does not serve (or an unusable value, reported as unsupported:unnamed) — it is" >&2
      echo "refused under that name rather than read as npm. Fix or remove the field." >&2
      echo "Refusing rather than shipping broken CI. Tracking: Myceliq/quality-kit#7." >&2
      exit 78
      ;;
  esac
fi

# --- a pnpm stamp's CI must be able to READ the committed lockfile (#7) ------
# What:  refuse a pnpm repo whose lockfile generation and CI pnpm cannot meet.
# Where: still before ANY file is written, for the same reason as the block above.
# Why:   picking quality.pnpm.yml is only half of "the repo can install". That
#        workflow runs `corepack enable pnpm`, and corepack takes the version from
#        package.json `packageManager` when the repo declares one and otherwise
#        resolves `latest`. The lockfile generations are NOT interchangeable in
#        either direction — both measured here, both exit 1 with
#        ERR_PNPM_LOCKFILE_BREAKING_CHANGE:
#          pnpm 11 (what `latest` resolves today) on a lockfileVersion 6.0 lockfile,
#          pnpm 8.15.9 on a 9.0 one.
#        So a repo still on the pnpm 8 format that declares nothing gets a stamp
#        whose `pnpm install --frozen-lockfile` is guaranteed red: the stamp
#        SUCCEEDS, prints "stamped", and hands back CI that cannot install, which
#        is the failure #7 exists to end. The README documented the remedy from the
#        start; documentation is not a gate.
#        EXACT version, not a range: corepack rejects `pnpm@8.x` with "expected a
#        semver version", so a range declaration is refused whether or not a
#        lockfile is present — it fails the install step before the lockfile is
#        even read. A `+sha` suffix (what `corepack use` writes) is kept and fine.
# SCOPE:  what this proves is "nothing the repo has ALREADY committed makes the
#        install impossible" — the two facts a stamp can check without leaving the
#        box: the declaration is a spec corepack can parse, and the pnpm it selects
#        owns the lockfile generation. It does NOT prove the install succeeds. A
#        version that does not exist in the registry, and a well-formed digest that
#        is simply the wrong one, both need the tarball, and stamp.sh is
#        deliberately offline and deterministic (codex, round 8). Those two fail
#        LOUDLY in CI on the first run and cannot go silently green, which is the
#        class of failure #7 is about; the ones checked here could.
# ponytail: the two generations the kit knows, 6 and 9 — the same closed set as
#        check-drift.sh's PNPM_ROOTS, and unknown ones are refused there too. A
#        third generation is one change that teaches both. Ceiling: a repo on a
#        lockfile the kit has never seen cannot be stamped until it is taught.
if [ "$MANAGER" = pnpm ]; then
  python3 - "$REPO" <<'PY' || exit 78
import json, os, re, sys
repo = sys.argv[1]

def die(msg):
    print(msg, file=sys.stderr)
    print("Refusing rather than shipping CI that cannot install. "
          "Tracking: Myceliq/quality-kit#7.", file=sys.stderr)
    raise SystemExit(1)

try:
    pm = json.load(open(os.path.join(repo, "package.json"))).get("packageManager")
except Exception:
    pm = None
# NOT stripped. corepack does not trim the field — ` pnpm@8.15.9 ` (padded) gets
# "Unsupported package manager specification" (measured, corepack 0.35.0) — so
# normalising here would validate a string CI never sees (codex, round 7).
pm = pm if isinstance(pm, str) else ""

# Which pnpm major CI will run: the declared one, or None for corepack's `latest`.
declared = None
if pm.split("@")[0].strip() == "pnpm":
    # The CONDITION mirrors detect-manager.sh's name rule exactly, .strip() and
    # all, so every declaration the detector called pnpm is validated here. Read
    # them apart and a declaration slips between the two: `pnpm @9.0.0` detects
    # as pnpm, and under a stricter test here would skip validation entirely and
    # stamp as if nothing were declared (codex, round 3).
    # The CHECK is then the whole raw string, not a re-split or a trim of it — a
    # spec corepack accepts has no stray whitespace anywhere in it, inside or
    # around, and a bare "pnpm" with no version at all lands here too, which is
    # the one place that can say so.
    # The optional `+algo.hexdigest` suffix (what `corepack use` writes) is
    # VALIDATED, not discarded: corepack parses it and verifies the download
    # against it, so a malformed one is one more guaranteed-red install. The
    # algorithm and the digest LENGTH are both checked, because a digest of the
    # wrong length can never match whatever the tarball hashes to — `+sha512.abc`
    # is not merely suspicious, it is impossible (codex, round 4). Measured
    # rather than assumed: `corepack use pnpm@8.15.9` (corepack 0.35.0) writes
    # `pnpm@8.15.9+sha512.<128 lowercase hex>`. Lowercase only, for the same
    # reason — that is what corepack compares its own computed hex against.
    # ponytail: shape only. Ceiling: this cannot tell a well-formed digest from
    # the WRONG well-formed digest — that needs the tarball, and stamp.sh is
    # deliberately offline and deterministic. CI catches a mismatched digest;
    # this catches every malformed one, which is what a stamp can see.
    # STRICT semver, not a loose \d+: corepack rejects `pnpm@09.0.0` and
    # `pnpm@8.15.9-alpha.` with that same "expected a semver version" (both
    # measured, corepack 0.35.0), so a looser pattern here would wave through a
    # declaration CI cannot resolve (codex, round 5). Hence semver.org's own
    # grammar — numeric identifiers carry no leading zero, and a prerelease
    # identifier is never empty. Build metadata is deliberately absent: corepack
    # spends the `+` on the integrity suffix below.
    num = r"(?:0|[1-9]\d*)"
    pre = rf"(?:{num}|\d*[A-Za-z-][0-9A-Za-z-]*)"
    digests = {"sha1": 40, "sha224": 56, "sha256": 64, "sha384": 96, "sha512": 128}
    suffix = "|".join(rf"{a}\.[0-9a-f]{{{n}}}" for a, n in digests.items())
    m = re.fullmatch(
        rf"pnpm@({num})\.{num}\.{num}(?:-{pre}(?:\.{pre})*)?(?:\+(?:{suffix}))?", pm)
    if not m:
        die(f'package.json declares "packageManager": "{pm}", which corepack cannot resolve: it '
            'wants the exact form `pnpm@<semver>`, with no whitespace inside or around it '
            '(` pnpm@8.15.9 ` gives "Unsupported package manager specification"), and it rejects '
            'a range — `pnpm@8.x` gives "Invalid package manager specification in package.json '
            '(pnpm@8.x); expected a semver version" (both measured, corepack 0.35.0). '
            'The stamped workflow would then die in '
            '`corepack enable pnpm` before it ever read the lockfile. Declare an exact version, '
            'e.g. "packageManager": "pnpm@8.15.9" — optionally with the integrity suffix '
            '`corepack use` writes, e.g. "pnpm@8.15.9+sha512.<128 lowercase hex chars>", which '
            'corepack verifies the download against and therefore has to be well formed: a real '
            'algorithm (sha1/224/256/384/512) and that algorithm\'s exact digest length. Copy it '
            'from `corepack use pnpm@<version>` rather than typing it. Then re-stamp.')
    declared = int(m.group(1))

lock = os.path.join(repo, "pnpm-lock.yaml")
if not os.path.exists(lock):
    raise SystemExit(0)   # nothing to be incompatible with yet — the pre-reconcile flow

# The generation is a top-level scalar pnpm writes on its own line, quoted
# (`lockfileVersion: '9.0'`). Read it as a shape, not with a YAML parser: the kit
# takes no runtime dependencies, and an unreadable value falls through to the
# unknown-generation refusal below rather than being guessed at.
m = re.search(r"^lockfileVersion:[ \t]*(.+?)[ \t]*$", open(lock, encoding="utf-8", errors="ignore").read(), re.M)
gen = (m.group(1).strip("'\"") if m else "")
# The WHOLE value has to be a version before its first component means anything:
# reading the major out of `6.not-a-version` would accept a corrupt header as the
# pnpm 8 format on the strength of one leading digit (codex, round 6). A value
# that is not a dotted number has no major, so it falls into the
# unknown-generation refusal below — which is where anything unreadable belongs.
major = gen.split(".")[0] if re.fullmatch(r"\d+(?:\.\d+)*", gen) else ""

if major not in ("6", "9"):
    die(f"pnpm-lock.yaml declares lockfileVersion {gen!r}, a generation this kit does not know "
        "(it knows 6 and 9), so it cannot tell which pnpm CI has to run to read it — and the "
        "generations are not interchangeable, so guessing would ship a red install. Regenerate "
        "the lockfile with a pnpm the kit supports (pnpm 8 writes 6; pnpm 9-11 write 9), or "
        "raise Myceliq/quality-kit#7 to teach the kit the new schema.")

if major == "6" and declared != 8:
    die(f"pnpm-lock.yaml is lockfileVersion {gen} — the pnpm 8 format — but package.json "
        f"declares {('no packageManager' if not pm else 'packageManager ' + pm)}. "
        ".github/workflows/quality.yml runs `corepack enable pnpm`, which resolves `latest` "
        "without a declaration, and pnpm >= 9 REFUSES a version 6 lockfile outright "
        "(ERR_PNPM_LOCKFILE_BREAKING_CHANGE — measured, pnpm 11 against a lockfile written by "
        "pnpm 8.15.9). Stamping would hand back CI whose `pnpm install --frozen-lockfile` is "
        "guaranteed red. Pick one, then re-stamp:\n"
        '  - keep this lockfile: add "packageManager": "pnpm@8.15.9" to package.json (an EXACT '
        "version — corepack rejects a range like pnpm@8.x)\n"
        "  - or migrate it: run `pnpm install --lockfile-only` under pnpm >= 9, which rewrites "
        "pnpm-lock.yaml as lockfileVersion 9.0, and commit it")

if major == "9" and declared is not None and declared < 9:
    die(f'package.json declares "packageManager": "{pm}" but pnpm-lock.yaml is lockfileVersion '
        f"{gen}, which pnpm 8 refuses to read (ERR_PNPM_LOCKFILE_BREAKING_CHANGE — measured, "
        "pnpm 8.15.9 against a version 9 lockfile), so CI's `pnpm install --frozen-lockfile` is "
        "guaranteed red. Raise the declaration to the pnpm that wrote this lockfile (e.g. "
        '"pnpm@11.9.0"), or drop the field and let corepack resolve `latest`, then re-stamp.')
PY
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
  put "ts/quality.$MANAGER.yml"      644 .github/workflows/quality.yml
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
