#!/usr/bin/env bash
# What: integration test — a stamped repo's linter must NOT lint the kit's own
#       source when the stamped CI workflow checks it out into the repo at
#       .quality-kit-src/. Where: this kit's ts/.
# Why:  the workflow checks the kit out INSIDE the repo so the drift gate can
#       run before install. Until v0.4.1 nothing excluded it, so the repo linted
#       the kit's three oxlint configs as if they were repo code — each carries
#       two type assertions, so every CI burn-down count came out six higher
#       than any local run could reproduce. That made the ratchet unusable:
#       a locally seeded baseline could never match CI, and the only way to go
#       green was to bank a number nobody could explain. Caught on the first
#       repo ever to run the ratchet in CI (booking-platform).
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
KITROOT="$(cd "$DIR/.." && pwd)"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }

# Same contract as the sibling suites: needs an oxlint whose node_modules also
# has ultracite. Unset OXLINT_BIN skips cleanly rather than failing.
OXLINT="${OXLINT_BIN:-}"
if [ -z "$OXLINT" ] || ! command -v node >/dev/null 2>&1; then
  echo "SKIP kit-checkout ignore integration (set OXLINT_BIN to an oxlint whose node_modules has ultracite)"
  exit 0
fi
NM="$(cd "$(dirname "$OXLINT")/.." && pwd)"

for profile in nextjs vite node; do
  W="$(mktemp -d)"
  ln -s "$NM" "$W/node_modules"
  mkdir -p "$W/.quality"
  cp "$DIR/agent-legibility.ts" "$W/.quality/agent-legibility.ts"
  cp "$KITROOT/ts/oxlint.config.$profile.ts" "$W/oxlint.config.ts"
  cat > "$W/.quality-kit.json" <<'JSON'
{"version":"0.4.1","profile":"node","runner":"npm","pendingFlags":[],
 "ruleOverrides":{"burnDown":{},"permanent":{}},"ignoreOverrides":[]}
JSON

  # Reproduce what the CI workflow does: the whole kit, checked out in-repo.
  mkdir -p "$W/.quality-kit-src/ts"
  cp "$KITROOT"/ts/oxlint.config.*.ts "$W/.quality-kit-src/ts/"

  # A file that WOULD trip a rule if it were linted. Deliberately `func-style`,
  # a rule that fires WITHOUT --type-aware: the real inflation came from
  # `no-unsafe-type-assertion`, but that is type-aware, so a probe using it
  # reports nothing under a plain `oxlint` run and the test passes whether or
  # not the ignore works. (Confirmed: an assertion-based probe passed against
  # deliberately unfixed configs.) If .quality-kit-src is scanned this is
  # reported; if it is ignored, nothing is.
  PROBE='const y = () => 2;\nexport function bad() { return y(); }\n'
  printf "$PROBE" > "$W/.quality-kit-src/ts/probe.ts"
  # Positive control: the SAME violation in ordinary repo code. It must be
  # reported. Without it, "zero diagnostics from .quality-kit-src" is satisfied
  # just as well by a linter that never ran — a config-load failure, a missing
  # ultracite, an oxlint that died on startup. Silence is not proof.
  printf "$PROBE" > "$W/control.ts"

  ERR="$W.stderr"
  rc=0
  out="$(cd "$W" && "$OXLINT" -f json . 2>"$ERR")" || rc=$?

  # Do NOT swallow the exit status. oxlint exits non-zero both for "found
  # violations" (expected — the control trips one) and for "failed to run", and
  # only the output shape tells them apart: valid JSON carrying a diagnostics
  # list means it genuinely linted. Anything else is a failure to report, not
  # zero findings. (Flagged by CodeRabbit: the first version piped stderr to
  # /dev/null and `|| true`, so a crashed oxlint produced empty stdout, parsed
  # as zero diagnostics, and PASSed without testing anything.)
  read -r ran leaked controls <<<"$(python3 -c "
import json,sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
    diags = d['diagnostics']
    if not isinstance(diags, list): raise ValueError
except Exception:
    print('0 0 0'); sys.exit()
name = lambda x: (x.get('filename') or '').replace('./','')
print(1,
      len([x for x in diags if name(x).startswith('.quality-kit-src')]),
      len([x for x in diags if name(x) == 'control.ts']))" <<<"$out")"

  if [ "$ran" != 1 ]; then
    bad "$profile: .quality-kit-src excluded from the repo's lint" \
        "oxlint did not produce a diagnostics list (exit $rc): $(head -c 300 "$ERR")"
  elif [ "$controls" -lt 1 ]; then
    bad "$profile: .quality-kit-src excluded from the repo's lint" \
        "positive control was not reported — the linter ran but this probe no longer trips a rule, so the ignore assertion below proves nothing"
  elif [ "$leaked" != 0 ]; then
    bad "$profile: .quality-kit-src excluded from the repo's lint" \
        "$leaked diagnostic(s) came from the kit checkout"
  else
    ok "$profile: .quality-kit-src excluded from the repo's lint (control reported, kit checkout silent)"
  fi
  rm -r "$W"; rm -f "$ERR"
done

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
