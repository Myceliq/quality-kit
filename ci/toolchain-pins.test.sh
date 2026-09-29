#!/usr/bin/env bash
# What: the kit's own CI toolchain (ci/oxlint-toolchain) pins every tool at exactly the
#       version ts/pins.json pins for stamped repos. Where: quality-kit/ci.
# Why:  one source of truth (D13). ts/pins.json is what the fleet runs; the toolchain is
#       what the kit's own suites run. Two hand-maintained version lists drift silently,
#       and a kit suite green against vitest X says nothing about a fleet on vitest Y (#69).
#       Checked in both the manifest (what `npm install` asks for) and the lockfile (what
#       `npm ci` actually installs). vitest is REQUIRED in the toolchain, not merely
#       "equal if present": dropping it would leave real-vitest suites with nothing to run.
set -euo pipefail
ROOT="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"

node - "$ROOT/ts/pins.json" "$ROOT/ci/oxlint-toolchain/package.json" "$ROOT/ci/oxlint-toolchain/package-lock.json" <<'EOF'
const [pinsPath, pkgPath, lockPath] = process.argv.slice(2);
const read = (p) => JSON.parse(require("node:fs").readFileSync(p, "utf8"));
const pins = read(pinsPath);
const deps = read(pkgPath).dependencies ?? {};
const locked = read(lockPath).packages ?? {};
let fail = 0;
const bad = (msg) => { console.log(`FAIL ${msg}`); fail = 1; };
if (!("vitest" in deps)) bad("vitest missing from ci/oxlint-toolchain/package.json (ts/pins.json pins it; #69)");
// Driven by the toolchain's deps, not the pins: a tool the toolchain installs but
// ts/pins.json dropped would otherwise go unchecked at whatever version it holds.
let checked = 0;
for (const [name, have] of Object.entries(deps)) {
  const want = pins[name];
  if (want === undefined) { bad(`${name}: installed by the toolchain but not pinned in ts/pins.json`); continue; }
  checked++;
  if (have !== want) bad(`${name}: toolchain package.json ${deps[name]} != ts/pins.json ${want}`);
  const lockV = locked[`node_modules/${name}`]?.version;
  if (lockV !== want) bad(`${name}: toolchain package-lock.json ${lockV} != ts/pins.json ${want} (regenerate: npm install in ci/oxlint-toolchain)`);
}
// A check that compared nothing would pass forever.
if (checked === 0) bad("no toolchain dependency was compared against ts/pins.json");
if (!fail) console.log(`PASS toolchain matches ts/pins.json (${checked} tools)`);
process.exit(fail);
EOF
