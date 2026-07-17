#!/usr/bin/env bash
# What: tests for count-suppressions.sh. Where: quality-kit/bin.
# Why:  the suppression budget is a security-relevant gate — an undercount
#       lets agents smuggle disables past CI.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/src" "$T/node_modules/pkg" "$T/docs"
cat > "$T/src/a.ts" <<'EOF'
// oxlint-disable-next-line no-explicit-any
const x: any = 1;
// @ts-expect-error legacy shim
const y = x.q;
// @ts-ignore
const z = y;
EOF
printf 'v = 1  # noqa: E501\nw = 2  # type: ignore\n' > "$T/src/b.py"
printf '// oxlint-disable everything\n' > "$T/node_modules/pkg/c.ts"   # must NOT count

out="$(bash "$DIR/count-suppressions.sh" "$T")"
python3 -c "
import json,sys
d=json.loads('''$out''')
assert d=={'oxlint-disable':1,'ts-expect-error':1,'ts-ignore':1,'noqa':1,'type-ignore':1}, d
" && ok "counts + vendored exclusion" || bad "counts + vendored exclusion" "$out"

out2="$(bash "$DIR/count-suppressions.sh" "$(mktemp -d)")"
[ "$out2" = '{"oxlint-disable":0,"ts-expect-error":0,"ts-ignore":0,"noqa":0,"type-ignore":0}' ] \
  && ok "empty repo all zeros" || bad "empty repo all zeros" "$out2"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
