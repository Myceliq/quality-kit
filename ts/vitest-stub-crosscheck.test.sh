#!/usr/bin/env bash
# What: every row of #45's vitest stand-in, run twice on the same fixture repo state — once
#       through the stand-in, once through the real vitest at $VITEST_BIN, both as `run --changed`
#       from the fixture root — requiring the same exit code and output class from each.
#       Where: quality-kit/ts.
# Why:  ts/validate-fast.test.sh certifies the validate:fast script against a stand-in "modelled
#       on vitest 4.1.11", and nothing checked the model (#72): a stand-in that drifts from the
#       real binary keeps that suite green while the script it certifies is wrong. Expectations
#       come from RUNNING the stand-in, extracted from that suite's heredoc, never from a copied
#       table — editing a stand-in row changes what the real binary must match here.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }

# Required, never an absence-is-skip (the #40 hole): unset or empty fails, except under the named
# opt-out bin/selftest.sh and the stamped consumer `Kit self-test` step already use. A path that
# is set but not an executable file is a broken toolchain, not an absent one — it fails even then.
if [ -z "${VITEST_BIN:-}" ]; then
  if [ -n "${KIT_SELFTEST_NO_TOOLCHAIN:-}" ]; then
    echo "SKIP vitest stub cross-check: VITEST_BIN is unset and KIT_SELFTEST_NO_TOOLCHAIN opts out"
    exit 0
  fi
  echo "FAIL VITEST_BIN is unset or empty: set it to ci/oxlint-toolchain/node_modules/.bin/vitest (or set KIT_SELFTEST_NO_TOOLCHAIN to opt out)"
  exit 1
fi
if [ ! -f "$VITEST_BIN" ] || [ ! -x "$VITEST_BIN" ]; then
  echo "FAIL VITEST_BIN=$VITEST_BIN is not an executable file"
  exit 1
fi
# Absolute before the cd into each fixture: a relative VITEST_BIN would resolve inside the fixture.
REAL="$(cd "$(dirname "$VITEST_BIN")" && pwd)/$(basename "$VITEST_BIN")"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
# The suite writes only inside $T. The real run gets TMPDIR="$T/tmp" for node's own temp writes,
# and vite puts vitest's cache in node_modules/.vite beside the NEAREST package.json above the
# root: the fixture has none, so without this one the lookup walks up out of $T — a stray
# package.json anywhere above the temp dir would take the write outside it.
mkdir -p "$T/tmp"
printf '{"private": true}\n' > "$T/package.json"

# The stand-in, byte for byte from the quoted heredoc in validate-fast.test.sh.
STUB_START="cat >\"\$T/bin/vitest\" <<'EOF'"
if ! awk -v start="$STUB_START" '$0 == start { on = 1; next } on && $0 == "EOF" { found = 1; exit } on { print }
    END { exit !found }' "$DIR/validate-fast.test.sh" > "$T/stub" 2>/dev/null || [ ! -s "$T/stub" ]; then
  echo "FAIL vitest stub: no \`$STUB_START\` … EOF heredoc in $DIR/validate-fast.test.sh"
  exit 1
fi
chmod +x "$T/stub"

mk_fixture() { # → the #45 fixture repo (src/sum.ts, src/sum.test.ts, .gitignore, README.md), clean; any failed step → rc 1, no path
  local r s; r="$(mktemp -d "$T/fx.XXXXXX")" || return 1
  (cd "$r" && git init -q && git config core.hooksPath /dev/null && mkdir src \
    && printf 'export const sum = (a: number, b: number) => a + b;\n' > src/sum.ts \
    && printf 'import { expect, it } from "vitest";\nimport { sum } from "./sum";\nit("sums", () => expect(sum(1, 2)).toBe(3));\n' > src/sum.test.ts \
    && printf 'node_modules/\n' > .gitignore && printf '# fixture\n' > README.md \
    && git add -A && git -c user.name=t -c user.email=t@t commit -q -m fixture) || return 1
  s="$(git -C "$r" status --porcelain --untracked-files=all)" || return 1
  [ -z "$s" ] || return 1
  echo "$r"
}
fixture() { # $1=var → $1 := mk_fixture; a build failure stops the suite here
  local r
  r=$(mk_fixture) || { echo "FAIL fixture repo was not built"; exit 1; }
  printf -v "$1" '%s' "$r"
}
edit_sum() { printf 'export const two = 2;\n' >> "$1/src/sum.ts"; }
classify() { # $1=combined output → zero-collection | tests-ran | nothing (unclassifiable never matches)
  if printf '%s\n' "$1" | grep -qF 'No test files found, exiting with code 0'; then echo zero-collection
  elif printf '%s\n' "$1" | grep -qF '.test.ts'; then echo tests-ran
  # Real vitest 4.1.11's passing summary names no file (`Test Files  1 passed (1)`), while the
  # stub's canned output always does — so this arm only ever fires on the real side.
  elif printf '%s\n' "$1" | grep -qE 'Test Files +[0-9]+ passed'; then echo tests-ran
  fi
}
indent() { printf '%s\n' "$1" | sed 's/^/    | /'; }
row() { # $1=name $2=repo [VAR=value...]=stand-in knobs → one PASS/FAIL line for the row
  local s_out s_rc r_out r_rc s_cls r_cls
  set +e
  s_out=$(cd "$2" && env -u FAKE_VITEST_ZERO -u FAKE_VITEST_OUT -u FAKE_VITEST_RC -u FAKE_VITEST_BASE VITEST_LOG="$T/stub.log" "${@:3}" "$T/stub" run --changed 2>&1); s_rc=$?
  r_out=$(cd "$2" && env -u FAKE_VITEST_ZERO -u FAKE_VITEST_OUT -u FAKE_VITEST_RC TMPDIR="$T/tmp" "$REAL" run --changed 2>&1); r_rc=$?
  set -e
  s_cls="$(classify "$s_out")"; r_cls="$(classify "$r_out")"
  if [ -n "$s_cls" ] && [ "$s_rc" = "$r_rc" ] && [ "$s_cls" = "$r_cls" ]; then
    ok "$1: real vitest matches the stub (exit $s_rc, $s_cls)"
  else
    bad "$1: real vitest differs from the stub" "stub exit $s_rc ${s_cls:-unclassified}, real exit $r_rc ${r_cls:-unclassified}
  stub output:
$(indent "$s_out")
  real output:
$(indent "$r_out")"
  fi
}

fixture R; row "clean tree" "$R"

fixture R; mkdir -p "$R/node_modules/.cache" && echo x > "$R/node_modules/.cache/x"
if [ -n "$(git -C "$R" status --porcelain --untracked-files=all)" ]; then
  bad "ignored files" "fixture: node_modules/ is not ignored"
else
  row "ignored files" "$R"
fi

fixture R; edit_sum "$R"; row "unstaged edit" "$R"

fixture R; edit_sum "$R"; git -C "$R" add src/sum.ts; row "staged-only edit" "$R"

fixture R; printf 'export const sum = (a: number, b: number) => a - b;\n' > "$R/src/sum.ts"
row "failing test" "$R" FAKE_VITEST_OUT='FAIL src/sum.test.ts' FAKE_VITEST_RC=1

fixture R; echo more >> "$R/README.md"; row "docs-only edit" "$R"

fixture R; printf 'export const unused = 1;\n' > "$R/src/unused.ts"
row "uncovered source edit" "$R" FAKE_VITEST_ZERO=1

fixture R
printf 'import { expect, it } from "vitest";\nimport { sum } from "./sum";\nit("sums again", () => expect(sum(1, 2)).toBe(3));\n' > "$R/src/sum2.test.ts"
row "untracked test file" "$R"

# #80: the stand-in's FAKE_VITEST_BASE knob against the thing it models — a real config whose
# experimental.vcsProvider adds the files committed since a base ref. Committed change, clean tree.
fixture R
cat > "$R/vitest.config.mjs" <<'EOF'
import { execFileSync } from "node:child_process";
const git = (root, args) => execFileSync("git", args, { cwd: root, encoding: "utf8" }).split("\n").filter(Boolean);
export default {
  test: {
    experimental: {
      vcsProvider: {
        findChangedFiles: ({ root }) =>
          Promise.resolve([
            ...git(root, ["diff", "--name-only", "base...HEAD"]),
            ...git(root, ["diff", "--cached", "--name-only"]),
            ...git(root, ["ls-files", "--other", "--modified", "--exclude-standard"]),
          ]),
      },
    },
  },
};
EOF
if (cd "$R" && git add vitest.config.mjs && git -c user.name=t -c user.email=t@t commit -q -m config && git tag base \
    && edit_sum "$R" && git -c user.name=t -c user.email=t@t commit -q -am edit) \
    && [ -z "$(git -C "$R" status --porcelain --untracked-files=all)" ]; then
  row "committed change, clean tree, base-ref config" "$R" FAKE_VITEST_BASE=base
  # The armed control: the same repo state WITHOUT the knob is the stock provider, which the
  # config above must NOT behave like — so the row above is the config's doing, not the fixture's.
  set +e; s_out=$(cd "$R" && env -u FAKE_VITEST_BASE VITEST_LOG="$T/stub.log" "$T/stub" run --changed 2>&1); set -e
  [ "$(classify "$s_out")" = zero-collection ] \
    && ok "committed change, clean tree: the stub without the base-ref knob collects nothing" \
    || bad "committed change, clean tree: the stub without the base-ref knob collects nothing" "$s_out"
else
  bad "committed change, clean tree, base-ref config" "fixture: the committed edit was not built"
fi

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
