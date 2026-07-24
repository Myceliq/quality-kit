#!/usr/bin/env bash
# What: render a repo's ruff.toml — kit base plus its declared overrides.
# Where: quality-kit/bin; shared by stamp.sh (writes it) and check-drift.sh
#        (diffs the on-disk file against a fresh render).
# Why:  ruff cannot execute logic the way a TS config can, so python's override
#       wiring has to be baked into the file. One renderer on both sides is what
#       keeps "stamped" and "verified" from drifting apart.
set -euo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="$(cd "${1:?usage: render-ruff.sh <repo>}" && pwd)"
python3 - "$KIT" "$REPO" <<'PY'
import json, os, sys
kit, repo = sys.argv[1:3]
base = open(os.path.join(kit, "py/ruff.toml")).read().rstrip("\n").split("\n")
qk_path = os.path.join(repo, ".quality-kit.json")
qk = json.load(open(qk_path)) if os.path.exists(qk_path) else {}
# a malformed ruleOverrides (e.g. a string or list, not an object) must not
# traceback here — check-drift.sh runs this render BEFORE its own schema
# check can name the real remedy, so a crash here would surface as a raw
# traceback instead of a clean DRIFT message. Degrade to the base render;
# check_overrides() in check-drift.sh is still the authoritative shape gate.
ov = qk.get("ruleOverrides")
ov = ov if isinstance(ov, dict) else {}
# both kinds are rendered the same way: ruff has no warn severity, so burn-down
# rules are ignored-until-fixed and the drift ratchet re-selects them to count.
rules = sorted(set(ov.get("burnDown") or {}) | set(ov.get("permanent") or {}))
excl = sorted(qk.get("ignoreOverrides") or [])
arr = lambda xs: "[" + ", ".join(json.dumps(x) for x in xs) + "]"

# extend-exclude is a TOP-LEVEL ruff key; under [lint] ruff errors on an unknown
# key. extend-ignore is a [lint] key. The base already opens a [lint] table and
# TOML forbids duplicate tables, so splice around the existing one.
i = next((k for k, l in enumerate(base) if l.strip() == "[lint]"), len(base))
head, rest = base[:i], base[i:]
# find where the [lint] table body actually ends — the next top-level table
# declaration (not a [lint.*] subtable) — rather than assuming [lint] runs to
# EOF. That keeps extend-ignore inside [lint] even if the base later grows a
# table after it, instead of silently landing in whatever comes next.
j = next((k for k, l in enumerate(rest[1:], start=1)
          if l.strip().startswith("[") and not l.strip().startswith("[lint.")), len(rest))
lint_body, tail = rest[:j], rest[j:]
if excl:
    # normalize the blank line the base already carries before [lint], so the
    # rendered file has exactly one blank on each side of the inserted block
    # regardless of how the base is spaced — determinism includes whitespace.
    while head and not head[-1].strip():
        head.pop()
    head += ["", "# quality-kit: ignoreOverrides from .quality-kit.json",
             f"extend-exclude = {arr(excl)}", ""]
if rules:
    lint_body += ["# quality-kit: ruleOverrides from .quality-kit.json — burn-down",
                  "# entries are ignored-until-fixed and counted by check-drift.sh --ratchet.",
                  f"extend-ignore = {arr(rules)}"]
print("\n".join(head + lint_body + tail))
PY
