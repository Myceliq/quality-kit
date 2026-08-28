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
same bin/loc-budget.sh               .quality/loc-budget.sh
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
  same ts/agent-legibility.ts .quality/agent-legibility.ts
  same "ts/oxlint.config.$PROFILE.ts" oxlint.config.ts
  same ts/oxfmt.config.ts oxfmt.config.ts
  same ts/tsconfig.strict.json tsconfig.quality.json
  same ts/quality.yml .github/workflows/quality.yml
fi

python3 - "$KIT" "$REPO" "$PROFILE" <<'PY' || fail=1
import ast, json, os, re, stat, sys
kit, repo, profile = sys.argv[1:4]
rc = 0
def err(m):
    global rc; rc = 1; print(f"DRIFT: {m}", file=sys.stderr)

def _scan_outside_strings(s, on_char, quotes='"', keep_strings=True):
    # Char-by-char pass tracking string state (JSON's double quotes by default,
    # backslash escapes); everything inside a string literal is copied verbatim
    # unless keep_strings is off, and never interpreted. This
    # is what stops a decoy payload like {"_a":"/*", ...,"_b":"*/"} — a real
    # comment marker split across two separate string VALUES — from being
    # misread as an actual comment span: a blind whole-file regex would
    # delete everything between the two string literals (hiding whatever
    # sits between them from this gate) while tsc's own string-aware parser
    # still honors it. on_char(out, s, i, n) handles one char outside a
    # string and returns the next index; it must append to out itself.
    # in_str holds the OPEN quote character (or "" outside a string), so the same
    # scanner serves JS, where ' " and ` each close only themselves.
    out, i, n, in_str, esc = [], 0, len(s), "", False
    while i < n:
        c = s[i]
        if in_str:
            if keep_strings: out.append(c)
            if esc: esc = False
            elif c == "\\": esc = True
            elif c == in_str: in_str = ""
            i += 1
        elif c in quotes:
            in_str = c
            if keep_strings: out.append(c)
            i += 1
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

NEXT_FLOOR = (16, 3, 1)

def _semver(v):
    # "16.3.1" -> ((16,3,1), 1); "16.3.1-canary.0" -> ((16,3,1), 0). A prerelease
    # sorts BELOW its release per semver, which is also the conservative reading
    # for a gate whose miss is a silent segfault.
    base, _, pre = str(v).partition("-")
    nums = tuple(int(x) for x in base.split(".")[:3])
    return nums + (0,) * (3 - len(nums)), 0 if pre else 1

def check_next_floor():
    # next < 16.3.1 SEGFAULTS during `next build` under CI=1 against the kit's
    # pinned typescript@7. Measured on booking-platform, same commit, only the
    # Next version varying: 16.2.4 -> exit 139 then 134, deterministic; 16.3.1 ->
    # exit 0, and it type-checks with TS7. This is gated rather than documented
    # because both halves of the failure are invisible (cockpit#87):
    #   - Invisible locally. A non-CI `next build` sees typescript@7 as missing,
    #     shells out to `npm install typescript` and goes green, so developers
    #     see a passing build while CI and production crash.
    #   - No diagnostic where it lands. Vercel's log ends at "Command
    #     npm run build exited with 1" — nothing names TypeScript, Next, or a
    #     signal. So this message carries the explanation the crash lacks.
    # The LOCKFILE is the ground truth, not package.json: `npm ci` installs
    # exactly the lockfile, and a range like ^16.2.4 says nothing about which
    # version CI actually resolves.
    lock = os.path.join(repo, "package-lock.json")
    if not os.path.exists(lock):
        err(f"profile=nextjs cannot verify the next >= {'.'.join(map(str, NEXT_FLOOR))} floor without package-lock.json — commit the lockfile (quality.yml runs `npm ci`, which requires one regardless)")
        return
    lk = json.load(open(lock))
    # lockfileVersion 2/3 key packages by install path; v1 used a flat map.
    entry = lk.get("packages", {}).get("node_modules/next") or lk.get("dependencies", {}).get("next")
    if not entry or not entry.get("version"):
        err("profile=nextjs but package-lock.json pins no next version — run npm install to refresh the lockfile, then commit it")
        return
    got = entry["version"]
    try:
        below = _semver(got) < _semver(".".join(map(str, NEXT_FLOOR)))
    except ValueError:
        err(f"cannot parse the locked next version {got!r} — refresh package-lock.json with npm install")
        return
    if below:
        err(f"next {got} is below the required {'.'.join(map(str, NEXT_FLOOR))} — it SEGFAULTS in `next build` under CI=1 against the kit's pinned typescript@7 (exit 139/134, no diagnostic in the build log), while a local build silently installs its own TypeScript and passes. Run: npm install next@latest, then commit package-lock.json. See README 'Stamping a repo — known gotchas'")

def _clause_floor(c):
    # Lowest version one npm comparator admits: a 3-tuple, or None when the
    # comparator sets no lower bound at all (`<23`). ValueError = "this parser
    # does not know that form", which the caller turns into a fail-closed DRIFT.
    #
    # ponytail: deliberately NOT a semver-range engine. It accepts a closed list
    # of forms — >=, ^, ~, =, bare exact, and x-ranges — and refuses everything
    # else, because a gate that guesses at an exotic range is worse than one
    # that says "write >=22.12.0". Ceiling: hyphen ranges ("20 - 22"),
    # prereleases and build metadata are rejected rather than misread. Upgrade
    # path if a real repo ever needs one: extend the list, one form + one test
    # at a time, or take a dependency on a real semver implementation.
    #
    # A STRICT `>` is refused rather than approximated. Reading it as `>=` would
    # under-state the floor, and the honest floor of `>22.11.999` is 22.11.1000
    # — a real distinction no one wants a gate improvising. `>=` says the same
    # thing unambiguously, and the message names it.
    c = c.strip()
    if not c or c in ("*", "x", "X"):
        return (0, 0, 0)
    if c.startswith("<"):
        if not c.lstrip("<=").strip():
            raise ValueError(c)   # a bare comparator; see _tokens() for why
        return None
    for p in (">=", "^", "~", "="):
        if c.startswith(p):
            c = c[len(p):].strip()
            break
    parts = c.split(".")
    if len(parts) > 3:
        raise ValueError(c)
    nums = []
    for p in parts:
        if p in ("x", "X", "*"):
            nums.append(0)          # an x-range's floor is that segment at 0
        elif p.isdigit() and (p == "0" or not p.startswith("0")):
            nums.append(int(p))   # semver forbids a leading zero: >=024.0.0 is
                                  # not a valid range, so it is refused, not read
        else:
            raise ValueError(c)     # prerelease, build metadata, hyphen range, junk
    return tuple(nums + [0] * (3 - len(nums)))

def _clause_ceiling(c):
    # (version, inclusive) for a `<` / `<=` comparator, else None. The version
    # itself goes through _clause_floor's number parser, so junk still raises.
    c = c.strip()
    if not c.startswith("<"):
        return None
    inclusive = c.startswith("<=")
    rest = c[2 if inclusive else 1:].strip()
    v = _clause_floor("=" + rest)
    # npm EXPANDS a partial inclusive bound: `<=22` admits every 22.x, i.e.
    # `<23.0.0`, and `<=22.12` admits every 22.12.x. Comparing against the
    # zero-padded (22, 0, 0) instead would call ">=22.12.0 <=22" — a perfectly
    # ordinary range — unsatisfiable and block a conforming repo.
    n = 0
    for p in rest.split("."):
        if not p.isdigit():
            break
        n += 1
    if n == 0:
        return None   # `<=x` / `<*` — a wildcard bound constrains nothing, and
                      # expanding it to <1.0.0 would call a fine range empty
    if inclusive and n < 3:
        v = (v[0] + 1, 0, 0) if n <= 1 else (v[0], v[1] + 1, 0)
        inclusive = False
    return v, inclusive

def _branch_floor(branch):
    # AND within a branch: floor = the highest lower bound. None when the branch
    # admits NOTHING — ">=22.12.0 <22.12.0" clears the floor arithmetically while
    # matching no Node at all, so npm can satisfy it with nothing and an
    # engine-strict install fails everywhere. That must not read as conforming.
    toks = _tokens(branch)
    # At most ONE lower-bound clause per AND branch. Two of them can intersect
    # to nothing — "22.12.0 23" and "^22.12.0 ^23" match no Node at all while
    # arithmetically flooring at 23 — and deciding that needs an upper bound for
    # every form (^, ~, exact, x-range), i.e. the semver engine this parser
    # deliberately is not. Refusing the shape instead is two lines, fails
    # CLOSED, and costs nothing real: a second lower bound in one branch is
    # redundant at best. The message already names what to write.
    if len([c for c in toks if not c.strip().startswith("<")]) > 1:
        raise ValueError(branch)
    lows = [f for f in (_clause_floor(c) for c in toks) if f is not None]
    low = max(lows) if lows else (0, 0, 0)
    for c in toks:
        hi = _clause_ceiling(c)
        if hi and (low > hi[0] or (low == hi[0] and not hi[1])):
            return None
    return low

def _range_floor(rng):
    # `||` between branches is OR (floor = the LOWEST satisfiable branch floor).
    # That OR rule is the whole reason this is parsed rather than
    # string-compared: "^20.19.0 || >=22.12.0" — the range copied off oxlint, and
    # the first attempt at this constraint on booking-platform — reads as
    # satisfying 22.12.0 but actually admits Node 20.19.
    # Returns None when EVERY branch is empty, i.e. the range is unsatisfiable.
    floors = [f for f in (_branch_floor(b) for b in rng.split("||")) if f is not None]
    return min(floors) if floors else None

_OPS = (">=", ">", "<=", "<", "^", "~", "=")

def _tokens(branch):
    # npm allows whitespace between a comparator and its version, so a naive
    # split() turns ">=20 < 23" into [">=20", "<", "23"] — and that lone "23"
    # then reads as a LOWER BOUND of 23, so the range would be accepted while
    # actually admitting Node 20. Rejoin a bare comparator with the token after
    # it; a trailing one with nothing to join is caught in _clause_floor.
    out = []
    for t in branch.split():
        if out and out[-1] in _OPS:
            out[-1] += t
        else:
            out.append(t)
    return out

def check_engines_node(pkg):
    # The kit's pinned toolchain floors Node at 22.12.0: oxlint/oxfmt/vite (and
    # every one of their platform bindings) declare "^20.19.0 || >=22.12.0",
    # and ultracite pulls commander@15 at a flat ">=22.12.0" with NO Node 20
    # branch — so the intersection is 22.12.0, roughly two majors above what
    # Next alone asks for. Until this gate nothing in a stamped repo said so.
    # Why gate rather than document (cockpit#87): on Node 20.9–20.18 the failure
    # never names Node. `npm run validate` dies on the runtime before it looks
    # at the code, and with engine-strict the install fails outright. The
    # stamped quality.yml runs Node 24, so CI never sees it — only a developer
    # or a delegate on an older Node does, and by then the log is unreadable.
    # The canonical range lives in ts/engines.json, the same file stamp.sh
    # merges into package.json, so the stamper and the gate cannot drift apart.
    # PROFILE SCOPE: ts profiles only (nextjs/vite/node — all three install
    # ts/pins.json, so all three inherit the floor). The python profile has no
    # package.json and installs none of this toolchain (runner=make, with
    # ruff/pyright/pytest), so a Node floor there would be meaningless — this
    # is called from the non-python branch of main() only.
    want = json.load(open(os.path.join(kit, "ts/engines.json")))["node"]
    floor = _range_floor(want)
    eng = pkg.get("engines")
    got = eng.get("node") if isinstance(eng, dict) else None
    if not isinstance(got, str) or not got.strip():
        err(f'package.json declares no engines.node — the kit toolchain requires Node >= {".".join(map(str, floor))} (ultracite pulls commander@15 at a flat >=22.12.0, with no Node 20 branch). Add to package.json: "engines": {{ "node": "{want}" }}, or re-run quality-kit/bin/stamp.sh, which writes it')
        return
    try:
        have = _range_floor(got)
        if have is None:
            err(f'engines.node {got!r} is unsatisfiable — its lower and upper bounds exclude every Node version, so npm can select none and an engine-strict install fails everywhere. Set "engines": {{ "node": "{want}" }} in package.json')
            return
    except ValueError:
        err(f'cannot parse engines.node {got!r} — this gate accepts >=, ^, ~, =, an exact version and x-ranges (a strict > is refused: write >= instead), combined with spaces (AND) and || (OR); anything else is refused rather than guessed at. Write it as "{want}"')
        return
    if have < floor:
        err(f'engines.node {got!r} admits Node {".".join(map(str, have))}, below the {".".join(map(str, floor))} the kit toolchain requires — on an older Node `npm run validate` fails on the runtime before it reads any code, and with engine-strict the install itself fails, in neither case naming Node. Set "engines": {{ "node": "{want}" }} in package.json. See README "Stamping a repo — known gotchas"')

# Vitest's default include, as a regex: **/*.{test,spec}.?(c|m)[jt]s?(x). The
# kit ships no vitest config, so the default IS the collection rule — if the kit
# ever ships one with its own `include`, that file becomes the ground truth and
# this pattern must be changed to follow it. pytest's equivalent is its default
# python_files: test_*.py or *_test.py.
TEST_FILE_RE = {
    "python": re.compile(r"^(test_.*|.*_test)\.py$"),
    "ts": re.compile(r"\.(test|spec)\.[cm]?[jt]sx?$"),
}
# Each runner's OWN default exclusions, kept separate rather than unioned: a
# union would import vitest's `cypress` into the python scan and reject a repo
# whose cypress/test_smoke.py pytest really does collect. Both lists drop their
# dotted entry (vitest's .idea/.git/.cache/.output/.temp, pytest's blanket ".*")
# because dotted directories are skipped wholesale below.
SKIP_DIRS = {
    "ts": {"node_modules", "dist", "cypress"},          # vitest defaults
    "python": {"node_modules", "dist", "build", "venv", "CVS", "_darcs", "{arch}"},  # pytest norecursedirs
}
# Skipping every dotted directory is stricter than vitest's own list, and
# deliberately so: it is what keeps the kit's OWN in-repo checkout out of the
# scan. quality.yml clones the kit to .quality-kit-src INSIDE the repo before
# this gate runs, and v0.4.1 exists because that directory kept getting scanned
# by repo tooling. It costs a conforming repo nothing — nobody keeps their test
# suite in a dotfile directory.

# On BOTH runners the FILENAME alone is not enough, for different reasons.
# pytest imports a matching module and reports "no tests ran" (exit 5) when it
# declares no item, so a helper named test_helpers.py hits the exact failure
# this gate exists to catch. Vitest does collect a matching file, but then fails
# it — "No test suite found in file …" when nothing is declared, or "it is not
# defined" when a bare global is called with `globals` at its default false.
# All three are the same red `validate` on day one, so each arm reads the file.
def _safe_read(path):
    # The repo is untrusted input to this gate. A committed symlink named
    # test_helpers.py pointing at /dev/zero would hang the gate or exhaust its
    # memory, so only a regular (non-symlink), sanely-sized file is ever read;
    # anything else simply does not count as a test file.
    try:
        st = os.lstat(path)
    except OSError:
        return None
    if not stat.S_ISREG(st.st_mode) or st.st_size > 4_000_000:
        return None
    return open(path, encoding="utf-8", errors="ignore").read()

# Vitest registers a suite through one of its declaration APIs. The leading
# (?:^|[^.\w]) keeps `foo.test(` (a method call on some object) from reading as
# a declaration, which is why the namespace form needs its own alternative.
# Comments and string literals are stripped first, in ONE string-aware pass: a
# wholly commented-out test file is an ordinary way to end up with a matching
# filename and no registered suite, and `const label = "it("` is text rather
# than a declaration. Treating either as evidence would wave a red repo through.
# ponytail: a regex over the file text. There is no TypeScript parser in the
# stdlib, so the ast trick used on the python side is not available here, and
# every remaining inaccuracy is one only a real parser could resolve:
#   - a local `function it(...)` SHADOWING the vitest global reads as a
#     declaration. Unfixable without semantic analysis; also not a thing that
#     happens by accident in a file named *.test.ts.
#   - stripping a template literal takes any `${ it(...) }` inside it with it.
#   - a regex literal containing a quote over-strips to the next quote.
# The last two can only hide a declaration, never invent one, so they cost a
# conforming repo at most an explicit second test file. Upgrade path if any of
# them ever bites a real repo: fall back to the filename check for ts.
VITEST_GLOBALS = ("it", "test", "describe", "suite", "bench")
# vitest's real declaration modifiers, split by what they RETURN. A terminal
# modifier registers the test itself (`test.skip("x", fn)`), so a call after it
# is a declaration. A factory returns a test FUNCTION and registers nothing until
# that result is called — `test.each([1])` alone leaves the file with no suite,
# and vitest fails it — so those need the second call to count. Anything else
# after the dot is not an API at all and throws at run time.
VITEST_TERMINAL = ("skip", "only", "todo", "fails", "concurrent", "sequential", "shuffle")
# `extend` is here too: invoked directly, `test.extend({…})("case", fn)` is a
# real declaration. Assigned to a name instead, the binding below tracks it.
VITEST_FACTORY = ("each", "for", "runIf", "skipIf", "extend")
# `extend` is a third shape: it returns a new test API normally BOUND to a name
# and called later, so the binding is tracked instead of the call site.
_VITEST_EXTEND_RE = r"(?:const|let|var)\s+(\w+)\s*=\s*(?:%s)\s*\.\s*extend\b"
# NOT `import type {…}`: TypeScript erases a type-only import entirely, so the
# call under it is unbound at run time and vitest throws "it is not defined".
# (The per-specifier `{ type it }` form falls out too — the specifier parser
# below matches a bare name or `name as alias`, and "type it" is neither.)
_VITEST_IMPORT_RE = re.compile(r"import\s*\{([^}]*)\}\s*from\s+vitest\b")
_VITEST_NS_RE = re.compile(r"import\s*\*\s*as\s+(\w+)\s*from\s+vitest\b")

def _strip_js_comments(src):
    # Comments gone, string literals KEPT — what the import scan needs, since a
    # vitest import is identified by its `from "vitest"` string. Scanning the
    # original source instead would bind a name off a COMMENTED-OUT import and
    # then accept the bare call below it, which vitest throws on.
    return _scan_outside_strings(src, _drop_comment, "\"'`")

def _strip_js_noncode(src):
    # ONE string-aware pass, in the only correct order: a `//` inside a string —
    # an ordinary "https://..." URL — must not open a comment, and a comment
    # marker must not open a string. Stripping either with a standalone regex
    # gets that wrong whichever way round they run, and the wrong answer here
    # blanks a real declaration and reports drift on a repo that is fine. This
    # is the same scanner the tsconfig reader uses, told about JS's three quote
    # characters and asked to drop the strings as well as the comments.
    return _scan_outside_strings(src, _drop_comment, "\"'`", keep_strings=False)

def _alt(names):
    return "|".join(re.escape(n) for n in sorted(names))

# A regex literal is code, not a call: `const marker = /it("smoke")/;` would
# otherwise read as a declaration once its inner string is masked. Only the
# positions where a regex may legally START are considered, so a division stays
# a division; blanking can hide a declaration but never invent one.
_JS_REGEX_LITERAL_RE = re.compile(
    r"(^|[=(,:\[!&|?{;]|\breturn|\btypeof|\bcase|\bdo|\bin|\bof)(\s*)"
    r"(/(?:\\.|\[(?:\\.|[^\]\\])*\]|[^/\\\n])+/[a-z]*)", re.M)

def _blank_js_regexes(src):
    # Blank each regex literal, keeping its length so nothing downstream shifts.
    # Only the positions where a regex may legally START are considered — after
    # an operator, a bracket, or a keyword like `return` — so a division stays a
    # division. Blanking can hide a declaration but never invent one.
    return _JS_REGEX_LITERAL_RE.sub(
        lambda m: m.group(1) + m.group(2) + " " * len(m.group(3)), src)

def _declares_vitest_suite(src, globals_ok):
    # A declaration has to be BOUND to be callable. Vitest's `globals` default is
    # FALSE, so a file whose only content is a bare `it("smoke", ...)` throws
    # "it is not defined" at run time — still a red validate, and exactly what
    # this gate must not wave through (it was also, before this, what the gate's
    # own suggested snippet told people to write). So a bare global counts only
    # when the repo's config turns `globals: true` on; otherwise the name must
    # come from a vitest import, named/aliased or namespace. Imports are read
    # with COMMENTS stripped but strings kept (a vitest import is identified by
    # its `from "vitest"` string, and a commented-out import binds nothing);
    # the call itself is matched with strings stripped too.
    # Imports are read from a MASKED copy that reveals only the `vitest`
    # specifier: comments are gone (a commented-out import binds nothing) and so
    # is every other string, so an import quoted inside a string cannot bind.
    imports = _mask_js_strings(_strip_js_comments(src), reveal={"vitest"})
    bound = set()
    for spec in _VITEST_IMPORT_RE.findall(imports):
        for part in spec.split(","):
            # `as` may be surrounded by any whitespace, newlines included — a
            # literal " as " split would miss `test as<tab>scenario` and report
            # drift on a suite that runs.
            m = re.match(r"\s*(\w+)(?:\s+as\s+(\w+))?\s*$", part, re.S)
            if m and m.group(1) in VITEST_GLOBALS:
                bound.add(m.group(2) or m.group(1))
    if globals_ok:
        bound |= set(VITEST_GLOBALS)
    ns = set(_VITEST_NS_RE.findall(imports))
    # Strings are MASKED here, not deleted: deleting a template literal turns
    # the documented tagged form `test.each`table`("case", fn)` into a bare
    # `test.each("case", fn)`, which the factory arm below rightly refuses —
    # blocking a suite vitest collects. Masking keeps the delimiters, so the
    # shape stays visible while the contents still cannot pose as code.
    # Regex literals are blanked FIRST: a `//` or `/*` inside one is not a
    # comment, and stripping comments first would eat the rest of the line —
    # taking a live declaration with it. Blanking keeps the length, so nothing
    # downstream shifts.
    code = _mask_js_strings(_strip_js_comments(_blank_js_regexes(src)))
    # A namespace-qualified head is `vitest.it`; the leading [^.\w] below
    # deliberately rejects a bare property access, so it needs its own head.
    heads = list(bound) + ["%s.%s" % (n, g) for n in ns for g in VITEST_GLOBALS]
    if not heads:
        return False
    # `const myTest = test.extend({...})` hands the API to a NEW name; track it,
    # or a file whose whole suite is written against myTest reads as empty.
    extra = set(re.findall(_VITEST_EXTEND_RE % _alt(heads), code))
    heads += sorted(extra - set(heads))
    # A declaration is a direct CALL, a terminal modifier called, or a factory
    # whose RESULT is called — the `)(`.
    # ponytail: the factory arm finds the FIRST `)(` after the modifier, which is
    # the right one for an ordinary (possibly multi-line) each-table. Ceiling: an
    # unrelated `)(` further down the file would satisfy it. Only a real parser
    # fixes that, and the upgrade path stays "fall back to the filename check".
    forms = (r"\s*\(",
             r"\s*\.\s*(?:%s)\s*\(" % _alt(VITEST_TERMINAL),
             r"\s*\.\s*(?:%s)\b[\s\S]*?\)\s*\(" % _alt(VITEST_FACTORY),
             r"\s*\.\s*(?:%s)\s*`[^`]*`\s*\(" % _alt(VITEST_FACTORY))
    pat = "|".join(r"(?:^|[^.\w])(?:%s)%s" % (_alt(heads), f) for f in forms)
    return bool(re.search(pat, code))

def _py_declares_test_item(src):
    # pytest's DEFAULT collection scopes, exactly: a TOP-LEVEL `test*` function,
    # or a `test*` method on a top-level `Test*` class. Nothing else is an item —
    # `class TestHelpers: pass` declares none, and a `def test_x` sitting on a
    # plain `class Helpers` is never collected either. A regex over the file text
    # gets that wrong in both directions (it either misses the method inside a
    # Test class or accepts one inside a non-Test class), so this walks the ast:
    # stdlib, and it is the same structural question pytest itself asks.
    # ponytail: default python_functions/python_classes only. Ceiling: items
    # produced by a collection plugin (pytest-bdd's scenarios(), pytest-describe),
    # a renamed python_functions, or a Test* class pytest skips for having an
    # __init__. Upgrade path if that ever bites a real repo: read the names out of
    # its pytest config, or drop back to the filename check.
    try:
        tree = ast.parse(src)
    except (SyntaxError, ValueError):
        return False    # pytest cannot import it either — it is not a working test
    fns = (ast.FunctionDef, ast.AsyncFunctionDef)
    classes = {n.name: n for n in tree.body if isinstance(n, ast.ClassDef)}
    refs = _unittest_refs(tree)
    cases = _testcase_names(tree)
    named = lambda ms, pred: any(isinstance(m, fns) and pred(m.name) for m in ms)
    # `__test__ = False` is pytest's own opt-out: it collects NOTHING from that
    # module (or class), however many test_* names it carries. Ignoring it would
    # let a deliberately-excluded file stand as proof of a suite.
    if _opted_out(tree.body):
        return False
    unknown = False
    # `test_x.__test__ = False` disables ONE item; pytest reads that attribute at
    # collection time, so the function is not evidence of a suite either.
    disabled = _attr_opted_out(tree.body)
    for node in tree.body:
        if isinstance(node, fns):
            # A fixture NAMED test_* is still a fixture: pytest excludes it from
            # collection, so it cannot stand as the repo's only test.
            if (node.name.startswith("test") and node.name not in disabled
                    and not _is_fixture(node)):
                return True
            continue
        if not isinstance(node, ast.ClassDef):
            continue
        if node.name in disabled:
            continue
        # inherited members count on BOTH sides: pytest collects a test_* method
        # a class inherits, and equally refuses a class whose __init__ is
        # inherited, so neither question may stop at node.body.
        members = _members(node, classes)
        if _opted_out(members):
            continue
        # A base this module cannot see — imported from elsewhere, and not one of
        # the unittest spellings — may or may not carry the test methods, and
        # NEITHER answer is knowable here. Declaring the class empty would BLOCK
        # a valid suite; counting it as one would PASS a repo pytest collects
        # nothing from. So it decides neither: it records "cannot tell", and the
        # caller hands the whole check off, loudly. Same rule as the
        # custom-collection hand-off — never decide what cannot be evaluated.
        opaque = any(_base_name(b) not in classes and _base_ref(b) not in refs
                     for b in node.bases)
        # a method can be switched off inside the class body too —
        # `class TestSmoke: ...; test_x.__test__ = False` leaves pytest nothing
        # to collect from it.
        off = _attr_opted_out(members)
        # a fixture METHOD named test_* is excluded from collection just as a
        # top-level fixture function is
        if not any(isinstance(m, fns) and m.name.startswith("test")
                   and m.name not in off and not _is_fixture(m) for m in members):
            if opaque and (node.name in cases or node.name.startswith("Test")):
                unknown = True
            continue
        # unittest FIRST: pytest's unittest integration collects ANY TestCase
        # subclass in a collected module, whatever the class is called
        # (python_classes does not govern it) and regardless of a constructor —
        # TestCase defines its own __init__.
        if node.name in cases:
            return True
        # python_classes default (Test*), minus pytest's constructor exclusion:
        # it refuses to collect a Test* class with a resolved __init__/__new__,
        # warns, and collects nothing — which is the empty-collection exit 5
        # this gate exists to catch, so that class is not evidence of a test.
        if node.name.startswith("Test") and not named(members, lambda n: n in ("__init__", "__new__")):
            # An unseen base may itself define __init__, which would make pytest
            # skip the class however many test_* methods it declares here. Not
            # knowable statically, so it records "cannot tell" like the case
            # above rather than certifying the repo. (A unittest.TestCase
            # subclass returned True already: pytest collects those regardless
            # of a constructor.)
            if opaque:
                unknown = True
                continue
            return True
    return None if unknown else False

def _is_fixture(node):
    # Any decorator whose dotted path ends in `fixture` — @pytest.fixture,
    # @fixture, @pytest_asyncio.fixture, with or without arguments.
    for d in node.decorator_list:
        ref = _base_ref(d.func if isinstance(d, ast.Call) else d)
        if ref and ref[-1] == "fixture":
            return True
    return False

def _attr_opted_out(body):
    # Names disabled by a module-level `name.__test__ = False`.
    out = set()
    for n in body:
        if not isinstance(n, ast.Assign) or not isinstance(n.value, ast.Constant):
            continue
        if n.value.value is not False:
            continue
        for t in n.targets:
            if isinstance(t, ast.Attribute) and t.attr == "__test__" and isinstance(t.value, ast.Name):
                out.add(t.value.id)
    return out

def _opted_out(body):
    # `__test__ = False` anywhere in a module or class body (inherited members
    # included — _members flattens same-module bases before this runs).
    for n in body:
        targets = n.targets if isinstance(n, ast.Assign) else \
                  [n.target] if isinstance(n, ast.AnnAssign) else []
        if (any(isinstance(t, ast.Name) and t.id == "__test__" for t in targets)
                and isinstance(n.value, ast.Constant) and n.value.value is False):
            return True
    return False

def _members(node, classes, seen=None):
    # A class's own body plus the bodies of its same-module bases, transitively.
    # `seen` also stops a pathological base cycle from recursing forever.
    # ponytail: same-module bases only, like _testcase_names. Ceiling: a base
    # imported from another module — its methods and its constructor are both
    # invisible here. Upgrade path if that bites: nothing static resolves an
    # import; fall back to the filename check.
    seen = seen if seen is not None else set()
    out = list(node.body)
    for b in node.bases:
        nm = _base_name(b)
        if nm in classes and nm not in seen:
            seen.add(nm)
            out += _members(classes[nm], classes, seen)
    return out

def _base_name(b):
    # The name of a base ONLY when it is a bare local reference. A dotted base
    # such as `helpers.Base` must not resolve to a same-module `class Base` by
    # its tail: that would borrow the wrong class's methods in one direction and
    # hide a real opaque base in the other. Dotted paths go through _base_ref.
    return b.id if isinstance(b, ast.Name) else ""

def _base_ref(b):
    # The full dotted path of a base expression: ("unittest", "case", "TestCase")
    # for unittest.case.TestCase, ("TestCase",) for a bare name. Anything that
    # is not a plain dotted name (a subscript, a call) yields ().
    parts = []
    while isinstance(b, ast.Attribute):
        parts.append(b.attr)
        b = b.value
    if not isinstance(b, ast.Name):
        return ()
    parts.append(b.id)
    return tuple(reversed(parts))

def _unittest_refs(tree):
    # Every dotted path in THIS module that really means unittest.TestCase,
    # resolved from its own imports — NOT guessed from a name suffix, which
    # would let a local `class FauxTestCase` masquerade as one and wave through
    # a file pytest collects nothing from. Covers `unittest.TestCase`,
    # `unittest.case.TestCase`, a bare `TestCase` from `from unittest import
    # TestCase`, and `case.TestCase` from `from unittest import case` — with
    # every alias each of those forms can carry.
    refs, pkg, mod = set(), set(), set()   # bare names, `unittest`, `unittest.case`
    for n in ast.walk(tree):
        if isinstance(n, ast.Import):
            for a in n.names:
                if a.name == "unittest":
                    pkg.add((a.asname,) if a.asname else ("unittest",))
                elif a.name == "unittest.case":
                    # `import unittest.case` binds the TOP package unless aliased
                    if a.asname:
                        mod.add((a.asname,))
                    else:
                        pkg.add(("unittest",))
                        mod.add(("unittest", "case"))
        elif isinstance(n, ast.ImportFrom) and n.module in ("unittest", "unittest.case"):
            for a in n.names:
                if a.name == "TestCase":
                    refs.add((a.asname or a.name,))
                elif a.name == "case" and n.module == "unittest":
                    mod.add((a.asname or a.name,))
    return (refs | {p + ("TestCase",) for p in pkg} | {m + ("TestCase",) for m in mod}
                 | {p + ("case", "TestCase") for p in pkg})

def _testcase_names(tree):
    # Every top-level class in THIS module that is a unittest.TestCase subclass,
    # following same-module inheritance to a fixpoint: `class Base(unittest.TestCase)`
    # then `class Smoke(Base)` is collected by pytest, so recognising only a direct
    # TestCase base would report drift on a valid unittest-style suite.
    # ponytail: same-module bases only. Ceiling: a base imported from another
    # module. Upgrade path if that bites: nothing static resolves it — fall back
    # to the filename check.
    refs = _unittest_refs(tree)
    names, changed = set(), True
    while changed:
        changed = False
        for n in tree.body:
            if isinstance(n, ast.ClassDef) and n.name not in names and any(
                    _base_ref(b) in refs or _base_name(b) in names for b in n.bases):
                names.add(n.name)
                changed = True
    return names

# Vitest's default exclude has one FILE-level arm alongside its directory ones:
# **/{karma,rollup,…}.config.* — so a candidate named webpack.config.test.ts is
# excluded by name however well it matches the include, and must not satisfy
# this gate either.
VITEST_EXCLUDED_FILE_RE = re.compile(
    r"^(karma|rollup|webpack|vite|vitest|jest|ava|babel|nyc|cypress|tsup|build|eslint|prettier)\.config\.")

def _collects(path, name, pat, globals_ok=False):
    if not pat.search(name):
        return False
    if profile != "python" and VITEST_EXCLUDED_FILE_RE.match(name):
        return False
    src = _safe_read(path)
    if src is None:
        return False
    if profile == "python":
        return _py_declares_test_item(src)
    return _declares_vitest_suite(src, globals_ok)

# A repo may configure its runner's collection away from the defaults. Nothing
# static can evaluate `include: ['**/*.check.ts']` inside a TypeScript config,
# and guessing is worse than an honest hand-off in BOTH directions: claiming "no
# test file found" would block a repo whose suite runs fine — causing the very
# day-one red this gate exists to prevent — while quietly accepting the repo
# would hide a real empty collection. So when a repo declares its own collection
# rules the check steps aside and SAYS SO on stderr. The kit's default-shape
# guarantee simply does not extend to that repo, and the case this gate exists
# for — a fresh stamp with no tests at all — never carries such a config.
# The filenames vitest ACTUALLY resolves, extension included. A prefix match
# would take `vite.config.backup` for a config: vitest ignores that file, still
# collects by its defaults, and the repo stays red — while the gate, seeing a
# `test: { include: … }` inside it, would have handed the check off.
TS_RUNNER_CONFIGS = re.compile(
    r"^(?:vite|vitest)\.config\.(?:[cm]?[jt]s)$|^vitest\.workspace\.(?:[cm]?[jt]s|json)$")
# Each config file's OWN pytest section: a key anywhere else in the file is not
# a pytest setting at all.
PY_PYTEST_SECTIONS = {
    "pyproject.toml": "tool.pytest.ini_options",
    "pytest.ini": "pytest",
    "tox.ini": "pytest",
    "setup.cfg": "tool:pytest",
}
# norecursedirs belongs here too: overriding it can hide the very directory the
# scan found a test in, so pytest collects nothing while this gate sees a file.
# addopts is here for the same reason and treated conservatively — ANY addopts
# hands off, without inspecting the flags. `--ignore`, `--deselect`, `-k` and
# `-m` can each reduce collection to nothing, and INI continuation lines mean
# the flags often are not on the key's own line, so sniffing the value would be
# unreliable in the direction that matters. Handing off costs a benign
# `addopts = -q` only a stderr notice.
PY_COLLECT_HOOK_RE = re.compile(
    r"^\s*collect_ignore(_glob)?\s*=|^\s*def\s+pytest_(ignore_collect|collect_file|collection_modifyitems)\b",
    re.M)
PY_COLLECT_KEYS = ("python_files", "python_classes", "python_functions",
                   "testpaths", "norecursedirs", "addopts")

def _py_collection_override(name, src):
    # Section-aware, comment-aware. A raw whole-file regex would take
    # `python_files` out of an unrelated [tool.*] table, or out of a commented
    # line, and wave the test-file check aside on a repo pytest collects
    # nothing from — turning the hand-off into a bypass.
    want, section = PY_PYTEST_SECTIONS[name], None
    for line in src.splitlines():
        line = line.strip()
        if not line or line[0] in "#;":
            continue
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1].strip()
        # pytest's INI parser accepts `:` as a key/value delimiter as well as
        # `=`, and TOML permits a quoted key — miss either and a valid override
        # reads as absent, so the gate enforces its defaults on a repo that has
        # legitimately moved its collection elsewhere.
        elif section == want and re.split(r"[:=]", line, maxsplit=1)[0].strip().strip("\"'") in PY_COLLECT_KEYS:
            return True
    return False
# Quoted keys are normalized to bare ones before any of these run (see
# _unquote_js_keys), so the patterns stay simple. The residual: suite-like text
# inside a string VALUE inside the test block can still trigger a hand-off — and
# a hand-off never accepts a broken file, so that direction is safe.
TS_TEST_BLOCK_RE = re.compile(r"(?:^|[^.\w])test\s*:\s*\{")
# `test` named as a config property WITHOUT a literal block after it — a
# shorthand (`defineConfig({ test })`) or an identifier (`test: myConfig`). The
# settings then live somewhere this gate cannot follow, so such a config is
# unevaluable and hands off rather than having the defaults enforced on it.
TS_TEST_INDIRECT_RE = re.compile(r"(?:^|[^.\w])test\s*[:,}]")

_JS_QUOTED_KEY_RE = re.compile(r"""(["'])(\w+)\1(?=\s*:)""")

def _unquote_js_keys(code):
    # `"include":` -> ` include :` — the two quote characters become spaces, so
    # every offset still lines up with the original. A quoted string immediately
    # followed by `:` in an object literal IS a key; rewriting it bare lets the
    # plain patterns see it, and lets string masking hide everything that is
    # genuinely a value.
    return _JS_QUOTED_KEY_RE.sub(lambda m: " " + m.group(2) + " ", code)

def _mask_js_strings(code, reveal=()):
    # Replace every string literal's CONTENT with x, keeping the quotes and the
    # exact length. Two things need opposite treatment here: finding the `test:
    # {…}` block must ignore string contents (or `label: "test: { include: [] }"`
    # would pass for a real config, and a `{` inside a string would unbalance the
    # brace count), while reading the KEYS inside that block must see them (a
    # config may write `"include":`). Masking gives both: search the mask, slice
    # the original at the same offsets.
    #
    # `reveal` names string CONTENTS to leave readable, with the quotes turned
    # into spaces so the length still matches. That is how a `from "vitest"`
    # specifier survives masking while every other string does not — and a
    # `"vitest"` sitting INSIDE another string is never scanned as a literal of
    # its own, so it can never be revealed. That is what stops an import quoted
    # inside a string from binding names that do not exist at run time.
    out, quote, esc, buf = [], "", False, []
    for c in code:
        if quote:
            if esc:
                esc = False; buf.append(c)
            elif c == "\\":
                esc = True; buf.append(c)
            elif c == quote:
                text = "".join(buf)
                out.append(" " + text + " " if text in reveal
                           else quote + "x" * len(text) + quote)
                quote, buf = "", []
            else:
                buf.append(c)
        elif c in "\"'`":
            quote, buf = c, []
        else:
            out.append(c)
    if quote:                       # unterminated literal
        out.append(quote + "x" * len(buf))
    return "".join(out)

def _js_block_span(masked, start):
    # (start, end) of the brace-matched {...} beginning at masked[start]. Runs on
    # MASKED text, so plain brace counting is safe. Scoping matters: searching
    # everything AFTER a `test: {}` would find an unrelated optimizeDeps.include
    # further down the file and wave the whole check aside on it.
    depth = 0
    for i in range(start, len(masked)):
        if masked[i] == "{":
            depth += 1
        elif masked[i] == "}":
            depth -= 1
            if depth == 0:
                return start, i + 1
    return start, len(masked)

def _vitest_test_blocks():
    # [(config filename, its `test: { … }` block text, indirect?)] for EVERY
    # vite/vitest
    # config in the root — the places the repo can turn `globals` on or point
    # `include` somewhere else. All of them, not the first: `vite.config.ts`
    # sorts before `vitest.config.ts`, and stopping at a `vite.config.ts` that
    # merely sets `globals` would miss the `include` in the dedicated config
    # vitest actually uses, rejecting a repo that collects fine. Reading the
    # union errs toward handing off rather than blocking.
    out = []
    for name in sorted(os.listdir(repo)):
        if not TS_RUNNER_CONFIGS.match(name):
            continue
        src = _safe_read(os.path.join(repo, name))
        if not src:
            continue
        code = _unquote_js_keys(_strip_js_comments(src))
        masked = _mask_js_strings(code)  # ...but the block is FOUND on the mask
        region, opaque = _exported_region(masked)
        off = len(masked) - len(region)
        m = TS_TEST_BLOCK_RE.search(region)
        if m:
            a, b = _js_block_span(region, m.end() - 1)
            out.append((name, code[off + a:off + b], False))
        else:
            out.append((name, "", opaque or bool(TS_TEST_INDIRECT_RE.search(region))))
    return out

_EXPORT_DEFAULT_RE = re.compile(r"export\s+default\s+")
_WRAPPER_CALL_RE = re.compile(r"\s*[A-Za-z_$][\w$]*\s*\(")

def _exported_region(masked):
    # (text from `export default` onward, is-the-exported-thing-opaque).
    #
    # Only the EXPORTED object is vitest's config. A `test: { … }` sitting in an
    # unrelated object earlier in the file — `const metadata = { test: {…} }` —
    # configures nothing, and treating it as a config would hand the check off on
    # a repo vitest still collects by its defaults.
    #
    # If what is exported is not an object literal — `export default config`, or
    # a wrapper around an identifier — then the settings live somewhere this gate
    # cannot follow, which is the round-26 indirect case: unevaluable, so hand
    # off rather than enforce defaults on it. Wrapper CALLS are peeled first, so
    # the ordinary `export default defineConfig({ … })` still reads as a literal.
    m = _EXPORT_DEFAULT_RE.search(masked)
    if not m:
        return masked, False        # no ESM default export: read the whole file
    region = masked[m.end():]
    body = region
    while True:
        w = _WRAPPER_CALL_RE.match(body)
        if not w:
            break
        body = body[w.end():]
    return region, re.match(r"\s*\{", body) is None

def _effective_vitest_globals():
    # Vitest gives the DEDICATED vitest.config.*/vitest.workspace.* precedence
    # over vite.config.* rather than merging them, and `globals` decides whether
    # a bare `it(...)` is bound — the ACCEPT direction — so this must not union
    # the two. (The hand-off below does union them on purpose: skipping a check
    # can never accept a broken file, so erring toward hand-off is safe there.)
    blocks = _vitest_test_blocks()
    dedicated = [b for n, b, _ in blocks if n.startswith("vitest.")]
    chosen = dedicated[0] if dedicated else (blocks[0][1] if blocks else "")
    return bool(re.search(r"\bglobals\s*:\s*true\b", chosen))

_GLOBALS_VALUE_RE = re.compile(r"\bglobals\s*:\s*([A-Za-z_$][\w$]*|\S)")

def _dynamic_globals(block):
    # True when `globals` is set to anything other than the two literals. A
    # negative lookahead cannot express this: `\s*` backtracks to zero and the
    # lookahead then succeeds at the space, so `globals: false` would read as
    # dynamic. Capture the value and compare it instead.
    m = _GLOBALS_VALUE_RE.search(block)
    return bool(m) and m.group(1) not in ("true", "false")

def _custom_collection():
    # Root only: that is where both runners look for their config.
    if profile != "python":
        # include is not the only collection-affecting key: `exclude` can drop
        # the very files this scan found, `dir` moves the root the runner looks
        # under, and `includeSource` puts the suites INSIDE source files behind
        # `import.meta.vitest`, where no *.test.* filename exists at all. Each
        # means the same thing here — the kit's default shape no longer
        # describes what vitest will collect.
        for name, block, indirect in _vitest_test_blocks():
            # A `globals` whose value is computed (`process.env.CI === "true"`)
            # is as unevaluable as a custom include: assuming false would block
            # a bare-`it` suite that runs fine under validate's own environment.
            if (indirect or re.search(r"\b(includeSource|include|exclude|dir)\s*:", block)
                    or _dynamic_globals(block)):
                return name
        return None
    # A root conftest.py can exclude files from collection outright
    # (collect_ignore, pytest_ignore_collect, …). Nothing static evaluates those
    # hooks, so a repo that uses them gets the same hand-off as a custom
    # python_files rather than having the kit's defaults enforced on it.
    # pytest loads a directory-local conftest.py as well as the root one, and
    # any of them can exclude the very file this scan found.
    for root, dirs, files in os.walk(repo):
        dirs[:] = [d for d in dirs if not d.startswith(".") and d not in SKIP_DIRS["python"]]
        if "conftest.py" not in files:
            continue
        conf = _safe_read(os.path.join(root, "conftest.py"))
        if conf and PY_COLLECT_HOOK_RE.search(conf):
            return os.path.relpath(os.path.join(root, "conftest.py"), repo)
    for name in sorted(os.listdir(repo)):
        if name not in PY_PYTEST_SECTIONS:
            continue
        src = _safe_read(os.path.join(repo, name))
        if src and _py_collection_override(name, src):
            return name
    return None

def check_test_files():
    # `test:unit` is in the canonical validate chain, and BOTH runners treat
    # "collected nothing" as a failure: `vitest run` exits 1, `pytest` exits 5
    # and make propagates it. So a repo stamped with no test file is red on day
    # one — a stamp that looks green and isn't (cockpit#87), the same shape as
    # the next floor above. Static pass, before npm ci: the remedy is to write a
    # test, which no amount of installing or retrying produces.
    # REJECTED alternative: `vitest run --passWithNoTests` in the canonical
    # scripts. It turns the same repo green, but by deleting the requirement
    # instead of meeting it — a stamped repo having tests is the point — and it
    # would then permanently absorb a later misconfiguration that stops
    # collecting the tests a repo already has.
    cfg = _custom_collection()
    if cfg:
        print(f"note: {cfg} declares its own test collection rules, which this gate cannot evaluate before install — the test-file check is skipped for this repo; its `validate` run is what proves the suite is non-empty", file=sys.stderr)
        return
    key = "python" if profile == "python" else "ts"
    pat, skip = TEST_FILE_RE[key], SKIP_DIRS[key]
    globals_ok = key == "ts" and _effective_vitest_globals()
    unknown = None
    # `*.egg` is a GLOB in pytest's norecursedirs, not a literal, so it cannot
    # live in the set above — a repo whose only match is vendor.egg/test_smoke.py
    # really does collect nothing.
    egg = key == "python"
    for root, dirs, files in os.walk(repo):
        dirs[:] = [d for d in dirs
                   if not d.startswith(".") and d not in skip and not (egg and d.endswith(".egg"))]
        for f in files:
            v = _collects(os.path.join(root, f), f, pat, globals_ok)
            if v is True:
                return
            # None = "cannot tell" (a collectable class standing on a base
            # imported from another module). Keep looking for a definite answer;
            # if none turns up, hand off rather than deciding it either way.
            if v is None and unknown is None:
                unknown = os.path.relpath(os.path.join(root, f), repo)
    if unknown:
        print(f"note: {unknown} declares a test class over a base imported from another module, which this gate cannot follow — the test-file check is skipped for this repo; its `validate` run is what proves the suite is non-empty", file=sys.stderr)
        return
    if profile == "python":
        err("no test file found — `make validate` runs `pytest -q`, which exits 5 when it collects nothing, so this repo is red on day one. Add at least one file matching pytest's default python_files (test_*.py or *_test.py) that declares an item pytest actually collects — a top-level `def test_*`, or a `test_*` method on a `Test*` class (one with no __init__) or on a unittest.TestCase subclass. e.g. tests/test_smoke.py: `def test_smoke(): assert True`. A matching filename holding only helpers still collects zero")
    else:
        err("no test file found — the stamped validate chain runs `vitest run`, which exits 1 when it collects nothing, so this repo is red on day one. Add at least one file matching vitest's default include **/*.{test,spec}.?(c|m)[jt]s?(x) that declares a suite — e.g. src/smoke.test.ts: `import { it } from \"vitest\"; it(\"smoke\", () => {});`. The import matters: vitest's `globals` default is FALSE, so a bare `it(...)` throws \"it is not defined\" unless your vitest config sets globals: true. A matching file declaring no suite at all is collected and then fails with \"No test suite found in file\", which is the same red. (node_modules, dist, cypress and dotted directories are not searched, nor are vitest's excluded *.config.* filenames; a custom `include` in a repo-owned vitest config cannot be evaluated before install, so name at least one test file to match the default too.)")

def main():
    check_overrides()
    check_test_files()
    if profile != "python":
        pkg = json.load(open(os.path.join(repo, "package.json")))
        check_engines_node(pkg)
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
        if profile == "nextjs":
            check_next_floor()
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
ov = json.load(open(sys.argv[1])).get('ruleOverrides') or {}
ov = ov if isinstance(ov, dict) else {}
bd = ov.get('burnDown')
# Coerce a malformed (non-dict) burnDown to {} so the ratchet is a no-op on it:
# check_overrides above already reports the shape error with its remedy, and a
# non-dict here would otherwise build a garbage --select and surface a
# misleading 'linter failed' DRIFT on top of the correct one.
print(json.dumps(bd if isinstance(bd, dict) else {}))" "$QK")"
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
      # capture the rc without letting set -e abort on it: baseline-rules.sh
      # exits non-zero (3 not installed, 4 crashed) and prints {} to stdout in
      # both cases. A crash must not be read as "{}" == "all burn-down
      # complete" — that would tell an automated repair-loop to delete the
      # entire ledger over a transient linter crash.
      BR_RC=0
      ACTUAL="$(bash "$KIT/bin/baseline-rules.sh" "$REPO" --select "$SEL" 2>/dev/null)" || BR_RC=$?
      if [ "$BR_RC" != 0 ]; then
        err "ratchet: the linter failed to run (baseline-rules.sh exit $BR_RC) — fix the linter/config and re-run; a crashed lint run must not be read as 'all burn-down complete'"
      else
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
fi

[ "$fail" = 0 ] && { echo "drift gate clean (kit $KITV, profile $PROFILE)"; exit 0; }
exit 1
