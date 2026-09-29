#!/usr/bin/env bash
# What: the kit's own CI toolchain (ci/oxlint-toolchain) pins every tool at exactly the
#       version ts/pins.json pins for stamped repos. Where: quality-kit/ci.
# Why:  one source of truth (D13). ts/pins.json is what the fleet runs; the toolchain is
#       what the kit's own suites run. Two hand-maintained version lists drift silently,
#       and a kit suite green against vitest X says nothing about a fleet on vitest Y (#69).
#       Checked in both the manifest (what `npm install` asks for) and the lockfile (what
#       `npm ci` actually installs). vitest is REQUIRED in the toolchain, not merely
#       "equal if present": dropping it would leave real-vitest suites with nothing to run.
#       python3, not node: the stamped `Kit self-test` step runs this before setup-node and
#       promises only bash, git and python3 — and a node-missing SKIP would silently turn
#       the drift check off exactly where node is absent.
set -euo pipefail
ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"

python3 - "$ROOT/ts/pins.json" "$ROOT/ci/oxlint-toolchain/package.json" "$ROOT/ci/oxlint-toolchain/package-lock.json" <<'EOF'
import json, sys
pins, pkg, lock = (json.load(open(p)) for p in sys.argv[1:4])
deps = pkg.get("dependencies", {})
locked = lock.get("packages", {})
fail = False
def bad(msg):
    global fail
    print(f"FAIL {msg}")
    fail = True
if "vitest" not in deps:
    bad("vitest missing from ci/oxlint-toolchain/package.json (ts/pins.json pins it; #69)")
# Driven by the toolchain's deps, not the pins: a tool the toolchain installs but
# ts/pins.json dropped would otherwise go unchecked at whatever version it holds.
checked = 0
for name, have in deps.items():
    want = pins.get(name)
    if want is None:
        bad(f"{name}: installed by the toolchain but not pinned in ts/pins.json")
        continue
    checked += 1
    if have != want:
        bad(f"{name}: toolchain package.json {have} != ts/pins.json {want}")
    lock_v = locked.get(f"node_modules/{name}", {}).get("version")
    if lock_v != want:
        bad(f"{name}: toolchain package-lock.json {lock_v} != ts/pins.json {want} (regenerate: npm install in ci/oxlint-toolchain)")
# A check that compared nothing would pass forever.
if checked == 0:
    bad("no toolchain dependency was compared against ts/pins.json")
if not fail:
    print(f"PASS toolchain matches ts/pins.json ({checked} tools)")
sys.exit(1 if fail else 0)
EOF
