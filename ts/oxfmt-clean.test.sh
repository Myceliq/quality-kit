#!/usr/bin/env bash
# What: regression test — the kit's own shipped oxlint.config.*.ts files must
#       already be oxfmt-clean under the kit's pinned oxfmt (pins.json).
#       Where: quality-kit/ts.
# Why:  v0.2.0 shipped oxlint.config.{nextjs,vite,node}.ts dirty under oxfmt
#       0.59.0. oxlint.config.ts is a byte-owned stamped file, so a dirty
#       source makes the stamped repo's `format:check` permanently red, and
#       running `format` to fix it rewrites the file and fails the drift
#       gate instead. Every v0.2.0 TS-profile stamp was unlandable as a
#       result — catch it here so a future edit can't reintroduce it.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }

# oxfmt.config.ts imports the "oxfmt" package, so it only resolves next to a
# node_modules that has oxfmt installed. Point OXFMT_BIN at one; CI installs
# the pinned toolchain and sets it. Unset (e.g. a consumer CI without the
# toolchain step) skips cleanly rather than failing the suite.
OXFMT="${OXFMT_BIN:-}"
if [ -z "$OXFMT" ] || ! command -v node >/dev/null 2>&1; then
  echo "SKIP oxfmt cleanliness check (set OXFMT_BIN to a node_modules/.bin/oxfmt)"
  exit 0
fi
NM="$(cd "$(dirname "$OXFMT")/.." && pwd)"

W="$(mktemp -d)"
ln -s "$NM" "$W/node_modules"
cp "$DIR/oxfmt.config.ts" "$W/"
mkdir -p "$W/.quality"
cp "$DIR/agent-legibility.ts" "$W/.quality/agent-legibility.ts"
cp "$DIR/oxlint.config.nextjs.ts" "$DIR/oxlint.config.vite.ts" "$DIR/oxlint.config.node.ts" "$W/"

if out="$("$OXFMT" --check "$W" 2>&1)"; then
  ok "shipped TS configs are oxfmt-clean"
else
  bad "shipped TS configs are oxfmt-clean" "$out"
fi

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
