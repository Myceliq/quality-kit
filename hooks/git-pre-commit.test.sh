#!/usr/bin/env bash
# What: tests for the quality-kit block in the global git pre-commit.
# Where: quality-kit/hooks. Why: pre-commit is the universal delegate gate —
# it must fire for stamped repos and stay a no-op for everything else.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$DIR/git-pre-commit"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }

T="$(mktemp -d)"
# A `.`-sourced hook that reaches its own `exit 0` terminates THIS script — status 0, no output,
# nothing asserted — and the suite reports success. Refuse to exit cleanly unless the run
# actually reached the end. Found by break-probing the knob fallback: removing it broke the
# LIB_ONLY seam and the whole suite went silently green.
SUITE_COMPLETED=0
trap 'rc=$?; rm -rf "$T"
      if [ "$SUITE_COMPLETED" != 1 ]; then
        echo "FAIL harness: the suite exited early (status $rc) without running to completion" >&2
        exit 1
      fi
      exit "$rc"' EXIT
mkdir -p "$T/bin"; printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/codex"; chmod +x "$T/bin/codex"
export PATH="$T/bin:$PATH"

mk() { # $1=fail(0|1) → stamped fixture with make runner
  local r; r="$(mktemp -d)"
  (cd "$r" && git init -q && git config core.hooksPath /dev/null && git -c user.name=ci -c user.email=ci@example.com commit -q --allow-empty -m init)
  printf '{"version":"0.1.0","profile":"python","runner":"make","pendingFlags":[]}' > "$r/.quality-kit.json"
  printf 'validate-fast:\n\t@exit %s\n' "$1" > "$r/Makefile"
  echo "$r"
}

R="$(mk 0)"; (cd "$R" && echo x > f.txt && git add f.txt && bash "$HOOK") \
  && ok "stamped+green commit allowed" || bad "stamped+green commit allowed" "blocked"
R="$(mk 1)"; rc=0; (cd "$R" && echo x > f.txt && git add f.txt && bash "$HOOK" 2>/dev/null) || rc=$?
[ "$rc" != 0 ] && ok "stamped+red commit blocked" || bad "stamped+red commit blocked" "allowed"
U="$(mktemp -d)"; (cd "$U" && git init -q && git config core.hooksPath /dev/null && echo x > f.txt && git add f.txt && bash "$HOOK") \
  && ok "unstamped repo unaffected" || bad "unstamped repo unaffected" "blocked"

# Regression: repo path containing a shell-metachar quote must not break runner
# detection (a naive python3 -c "...'$PATH'..." interpolation breaks here and
# silently falls back to npm). The make path is red (exit 1); the npm fallback
# path is deliberately made green (exit 0) via a package.json stub — so a buggy
# fallback-to-npm is indistinguishable from correct-make ONLY if both fail; here
# only the buggy path succeeds, giving the assertion teeth.
Q="$T/qu'ote"; mkdir -p "$Q"
(cd "$Q" && git init -q && git config core.hooksPath /dev/null && git -c user.name=ci -c user.email=ci@example.com commit -q --allow-empty -m init)
printf '{"version":"0.1.0","profile":"python","runner":"make","pendingFlags":[]}' > "$Q/.quality-kit.json"
printf 'validate-fast:\n\t@exit 1\n' > "$Q/Makefile"
printf '{"scripts":{"validate:fast":"true"}}' > "$Q/package.json"
rc=0; (cd "$Q" && echo x > f.txt && git add f.txt && bash "$HOOK" 2>/dev/null) || rc=$?
[ "$rc" != 0 ] && ok "quoted repo path still resolves runner (blocked as make, not npm no-op)" \
  || bad "quoted repo path still resolves runner" "allowed (runner detection silently fell back to npm)"

# --- Verdict parsing --------------------------------------------------------
#
# Every case below is a commit that DID pass while the hook printed a success
# message, or a real Codex review captured from this repo. The gate is the last
# automated check before a commit lands, and its failure mode is silence — it
# prints "✓ No issues flagged" whether it evaluated the review or merely failed
# to understand it. These assert the difference.

# Reach codex_verdict() without running the gate itself.
#
# If the LIB_ONLY seam ever stops working, the sourced hook runs on to the gate and hits its own
# `exit 0` for "nothing staged" — which, because this is a `.` source, exits THIS SCRIPT, with
# status 0 and no output. The suite then reports success having asserted nothing. That is the
# worst failure a test suite has, so prove the seam held before trusting anything below it.
CODEX_HOOK_LIB_ONLY=1 . "$HOOK"
if ! declare -F codex_verdict >/dev/null; then
  echo "FAIL harness: sourcing the hook did not define codex_verdict — the LIB_ONLY seam is broken" >&2
  exit 1
fi

check() {
  local name="$1" expected="$2" review="$3" got
  got="$(printf '%s' "$review" | codex_verdict)"
  [ "$got" = "$expected" ] && ok "$name" || bad "$name" "expected '$expected', got '$got'"
}

# --- findings block ---------------------------------------------------------
check "bracketed finding blocks" block \
  '- [P2] Wait after SIGKILL so timed-out children are reaped'
check "bolded marker still blocks" block \
  '- **[P1]** auth bypass in the session check'

# --- the approval-ordering bypasses -----------------------------------------
# Both of these committed. The LGTM check ran first, unanchored and
# case-insensitive, and exited 0 before the finding was ever examined.
check "conditional approval is not an approval" block \
  'LGTM apart from the [P1] SQL injection below.'
check "a QUOTED LGTM is not an approval" block \
  "The comment '// LGTM once tests pass' is stale. [P1] Buffer overflow at line 42."

# --- format drift ------------------------------------------------------------
# Positive evidence of findings in an unparseable shape. This printed
# "✓ No issues flagged" and committed. It is NOT the same as Codex being
# unavailable, so it must not fall open.
check "unbracketed priority blocks" drift \
  'P1: hardcoded credential leaks the API token.'
check "bulleted unbracketed priority blocks" drift \
  '- P3 - minor style nit in the parser'

# --- clean reviews must stay QUIET ------------------------------------------
# Verbatim Codex output from this repo. `codex exec review` imposes its own
# schema: it emits no marker and no verdict token on a clean diff, and ignored an
# explicit "end with VERDICT: CLEAN|ISSUES" instruction added to the prompt.
# Demanding a positive approval token therefore alarms on EVERY clean commit —
# which is how a real alarm gets trained away. If someone "hardens" the final
# branch into an inconclusive state, these two fail first.
check "real clean review passes quietly" clean \
  'The revised verdict parsing still blocks on explicit findings, accepts an explicit clean verdict, and preserves the previous fail-open behavior when the review format is inconclusive. I do not see a discrete correctness or security regression introduced by this diff.'
check "clean review naming priorities in prose passes" clean \
  'The change only reclassifies the UP036 routing tier. No P1-level concern is evident from the diff alone.'
check "explicit LGTM approves" lgtm 'LGTM'

# --- a review DISCUSSING the marker syntax is not a finding ------------------
# This gate reviews itself, so its own diff produces reviews full of marker text.
# Quoted/backticked markers are the review naming the syntax, not raising an
# issue. Narrow on purpose: a marker is still matched mid-sentence, because
# anchoring to line starts would hand back the "conditional approval" bypass above.
check "backticked marker in prose is not a finding" clean \
  'codex_verdict() blocks on every `[P0-9]` substring, even in explanatory prose.'
# A DOUBLE-QUOTED marker blocks, and a fenced one blocks. Both used to be
# stripped before matching, on the same "it's only discussing the syntax"
# reasoning as backticks — and that stripping was itself a fail-open path: a
# review that fences its findings, or returns them as JSON ("title":"[P1] ..."),
# had every marker deleted and came out clean. Erring toward a false block on a
# review that merely quotes a marker is the cheap error; the other one ships a
# real finding. Do not restore either strip to quiet a noisy self-review.
check "a double-quoted marker still blocks" block \
  'The parser should only look at real finding lines, not arbitrary "[P1]" text.'
check "a marker inside a fenced block still blocks" block \
'The diff under review reads:
```
[P1] example marker shown for context, not a real finding
```
No correctness issue found.'
check "JSON-shaped findings are not erased by quote stripping" block \
  '{"findings":[{"severity":"high","title":"[P1] SQL injection in the auth path"}]}'
# A COMPACT single-line fence is the shape the multi-line case never covered: the pairwise strip
# ate the outer ticks as an empty span and read the rest as an inline span, erasing the marker.
check "a compact single-line fenced finding still blocks" block \
  '```[P1] null deref```'
# ...and a fence may use any run of three or more, so the run must be matched in full.
check "a four-backtick fence run still blocks" block \
  '````[P1] null deref````'

# The shape fence-delimiter neutralisation alone did NOT cover: a marker in single backticks
# INSIDE a fence. Neutralising only the delimiters left the span's insides exposed to the inline
# strip, so the marker vanished and a trailing sign-off approved a real finding.
check "a marker in backticks inside a fence still blocks" block \
  '```see `[P1]` here```
LGTM'
check "a marker in backticks inside a multi-line fence still blocks" block \
  '```
here is the problem: `[P1]` null deref
```
LGTM'
# ...while the same shape OUTSIDE a fence remains a mention of the syntax, not a finding.
check "a backticked marker outside any fence is still not a finding" clean \
  'this gate blocks on every `[P1]` substring'

check "real finding outside a fenced block still blocks" block \
'```
context: existing code shown for reference
```
[P1] Real bug: input not validated.'
# An UNTERMINATED fence must hide nothing. A sed range delete (/^```/,/^```/d)
# runs to end-of-input when the closing fence never arrives, so one truncated
# review would swallow every finding after the opening fence and report clean —
# the exact silent pass this function exists to prevent. Truncation is routine:
# the hook caps its own transcript, and the runtime can cut output mid-fence.
check "unterminated fence does not swallow a later finding" block \
'Review of the diff:
```
some quoted code
[P1] Real bug: SQL injection in the auth path.'
check "unterminated fence, finding several lines later" block \
'```shell
rg -n something

[P2] Missing null check causes a crash.'
check "mid-sentence marker still blocks" block \
  'Otherwise fine, but the [P2] issue in the retry path remains unaddressed.'

# --- drift detection is separator-driven, and that is a deliberate limit -----
check "mid-sentence unbracketed priority blocks" drift \
  'The remaining problem is P1: the credential is still hardcoded.'
# A hyphen only separates when spaced. Glued to a word it is ordinary prose, and
# matching it would block clean reviews that merely name a tier.
check "priority-level prose stays clean" clean \
  'No P1-level concern is evident from the diff alone.'
check "spaced hyphen is a separator" drift '- P3 - minor style nit in the parser'
# KNOWN AND ACCEPTED GAP: a bare token with no separator is indistinguishable from
# prose. Catching "one P2 concern remains" means matching every mention of a
# priority level, which blocks ordinary clean reviews — a gate that blocks
# everything gets switched off. If Codex ever emits findings in this shape, fix it
# by restoring the bracketed marker contract, not by widening this regex.
check "bare priority token is NOT treated as a finding" clean \
  'One P2 concern remains open from the earlier review.'

# --- the GATE_SKIPPED contract (#13) ----------------------------------------
# Every path that reaches a commit without a completed review must say so in a machine-readable
# way, classify itself, and be refusable. A fake codex makes the transcript and exit code
# deterministic; the real hook runs unmodified.
GBIN="$T/gatebin"; mkdir -p "$GBIN"
cat > "$GBIN/codex" <<'FAKE'
#!/usr/bin/env bash
output_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) output_file="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$output_file" ] && : > "$output_file"
if [ -n "${FAKE_CODEX_TRANSCRIPT:-}" ] && [ -f "$FAKE_CODEX_TRANSCRIPT" ]; then
  cat "$FAKE_CODEX_TRANSCRIPT"
  cat "$FAKE_CODEX_TRANSCRIPT" >&2
fi
exit "${FAKE_CODEX_EXIT:-1}"
FAKE
chmod +x "$GBIN/codex"

GSTATE="$T/gatestate"; mkdir -p "$GSTATE/quality-kit"
GLOG="$GSTATE/quality-kit/gate-skips.log"

gate_repo() { # → unstamped repo with one staged file (no validate:fast in the way)
  local r; r="$(mktemp -d)"
  (cd "$r" && git init -q && git config core.hooksPath /dev/null \
     && git config user.email ci@example.com && git config user.name ci \
     && echo x > f.txt && git add f.txt)
  echo "$r"
}

run_gate() { # run_gate <repo> <outfile> [VAR=VAL ...]
  local r="$1" out="$2"; shift 2
  # -u the lib-only knobs: this script sources the hook as `CODEX_HOOK_LIB_ONLY=1 . "$HOOK"`, and
  # under POSIX mode an assignment prefixed to a special builtin PERSISTS in the shell. Bash's
  # default mode does not (checked), but if it ever ran under `sh` every gate case below would
  # return at the lib-only guard and assert nothing while still reporting green.
  (cd "$r" && env -u CODEX_HOOK_LIB_ONLY -u REVIEW_HOOK_LIB_ONLY \
     PATH="$GBIN:$PATH" XDG_STATE_HOME="$GSTATE" "$@" bash "$HOOK") >"$out" 2>&1
}

TR="$T/tr-sandbox";     printf 'Codex sandbox failed to initialize: seatbelt setup error\n' > "$TR"
TR_ERR="$T/tr-error";   printf 'Something unexpected went wrong\n' > "$TR_ERR"
TR_USAGE="$T/tr-usage"; printf 'usage limit exceeded; try again at 2026-08-29T00:00:00Z\n' > "$TR_USAGE"

# sandbox_init gets its own reason code — it was indistinguishable from any other crash, which
# is why it needed a human to notice rather than a count.
R="$(gate_repo)"
run_gate "$R" "$T/g1" FAKE_CODEX_TRANSCRIPT="$TR" FAKE_CODEX_EXIT=1 \
  && grep -q "GATE_SKIPPED reason=sandbox_init" "$T/g1" \
  && ok "sandbox_init has its own reason code" \
  || bad "sandbox_init has its own reason code" "$(tail -3 "$T/g1")"

# usage_limit is not stolen by the sandbox branch.
R="$(gate_repo)"
run_gate "$R" "$T/g2" FAKE_CODEX_TRANSCRIPT="$TR_USAGE" FAKE_CODEX_EXIT=1 \
  && grep -q "GATE_SKIPPED reason=usage_limit" "$T/g2" \
  && ok "usage_limit has its own reason code" \
  || bad "usage_limit has its own reason code" "$(tail -3 "$T/g2")"

# A reviewer that exits 0 having written nothing has not reviewed anything. This is the quietest
# skip of the lot — no crash, no error text — so it is the one most likely to be read as a pass.
R="$(gate_repo)"; rc=0
run_gate "$R" "$T/g0" FAKE_CODEX_EXIT=0 REVIEW_HOOK_REQUIRE_GATE=1 || rc=$?
{ [ "$rc" != 0 ] && grep -q "GATE_SKIPPED reason=empty_output" "$T/g0"; } \
  && ok "a successful run with empty output is a skip, and is refusable" \
  || bad "a successful run with empty output is a skip, and is refusable" "rc=$rc $(tail -3 "$T/g0")"

# An ordinary crash stays generic rather than being mislabelled.
R="$(gate_repo)"
run_gate "$R" "$T/g3" FAKE_CODEX_TRANSCRIPT="$TR_ERR" FAKE_CODEX_EXIT=1 \
  && grep -q "GATE_SKIPPED reason=error" "$T/g3" \
  && ok "an ordinary failure keeps reason=error" \
  || bad "an ordinary failure keeps reason=error" "$(tail -3 "$T/g3")"

# The skip is logged with a timestamp, reason and class — the count is the whole point.
last="$(tail -n 1 "$GLOG" 2>/dev/null || echo MISSING)"
printf '%s\n' "$last" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z[[:space:]]+error[[:space:]].*provider_failure$' \
  && ok "skips are logged with reason and class" \
  || bad "skips are logged with reason and class" "got: $last"

# The fail-open DEFAULT is unchanged — this adds visibility, not a new posture.
R="$(gate_repo)"
run_gate "$R" "$T/g4" FAKE_CODEX_TRANSCRIPT="$TR" FAKE_CODEX_EXIT=1 \
  && ok "default still permits an ungated commit" \
  || bad "default still permits an ungated commit" "$(tail -3 "$T/g4")"

# ...but a caller that needs a real gate can now refuse.
R="$(gate_repo)"; rc=0
run_gate "$R" "$T/g5" FAKE_CODEX_TRANSCRIPT="$TR" FAKE_CODEX_EXIT=1 REVIEW_HOOK_REQUIRE_GATE=1 || rc=$?
[ "$rc" != 0 ] && ok "REVIEW_HOOK_REQUIRE_GATE=1 refuses an ungated commit" \
  || bad "REVIEW_HOOK_REQUIRE_GATE=1 refuses an ungated commit" "allowed"

# A value supplied ONLY under the legacy name must still take effect, or the fallback is
# decoration and the rename silently downgrades whoever set it.
R="$(gate_repo)"; rc=0
run_gate "$R" "$T/g6" FAKE_CODEX_TRANSCRIPT="$TR" FAKE_CODEX_EXIT=1 CODEX_HOOK_REQUIRE_GATE=1 || rc=$?
{ [ "$rc" != 0 ] && grep -q "CODEX_HOOK_REQUIRE_GATE is deprecated" "$T/g6"; } \
  && ok "the legacy knob name still takes effect, with a deprecation notice" \
  || bad "the legacy knob name still takes effect" "rc=$rc $(tail -3 "$T/g6")"

# Strict mode travels with the stamp, so it survives a fresh clone and a CI runner that never
# sourced anyone's profile.
R="$(gate_repo)"
printf '{"version":"0.1.0","profile":"python","runner":"none","pendingFlags":[],"requireGate":true}' > "$R/.quality-kit.json"
rc=0
run_gate "$R" "$T/g7" FAKE_CODEX_TRANSCRIPT="$TR" FAKE_CODEX_EXIT=1 || rc=$?
[ "$rc" != 0 ] && ok "requireGate in .quality-kit.json refuses an ungated commit" \
  || bad "requireGate in .quality-kit.json refuses an ungated commit" "allowed"

# ...and an explicit env var still wins, so a deliberate one-off remains possible.
rc=0
run_gate "$R" "$T/g8" FAKE_CODEX_TRANSCRIPT="$TR" FAKE_CODEX_EXIT=1 REVIEW_HOOK_REQUIRE_GATE=0 || rc=$?
[ "$rc" = 0 ] && ok "an explicit env override beats the stamped setting" \
  || bad "an explicit env override beats the stamped setting" "$(tail -3 "$T/g8")"

# An oversized diff is structural: no retry and no other reviewer rescues it, so it is
# classified apart from an outage and announced rather than muttered.
R="$(gate_repo)"
run_gate "$R" "$T/g9" REVIEW_HOOK_MAX_DIFF_BYTES=1 FAKE_CODEX_EXIT=1 \
  && grep -q "THIS COMMIT IS NOT BEING REVIEWED" "$T/g9" \
  && tail -n 1 "$GLOG" | grep -qE 'oversize_diff.*structural' \
  && ok "oversize_diff warns loudly and logs as structural" \
  || bad "oversize_diff warns loudly and logs as structural" "$(tail -3 "$T/g9")"

# A malformed numeric knob must not abort the commit: set -e plus arithmetic makes a typo fatal,
# which would turn one bad value into a commit freeze across every stamped repo.
R="$(gate_repo)"
run_gate "$R" "$T/g10" REVIEW_HOOK_TIMEOUT_SECONDS=180s FAKE_CODEX_TRANSCRIPT="$TR_ERR" FAKE_CODEX_EXIT=1 \
  && grep -q "is not a non-negative integer" "$T/g10" \
  && ok "a malformed numeric knob falls back instead of freezing commits" \
  || bad "a malformed numeric knob falls back instead of freezing commits" "$(tail -3 "$T/g10")"

# A gate whose own logging fails must still let the commit through — best-effort, always.
UNW="$T/unwritable"; mkdir -p "$UNW/quality-kit"; chmod 000 "$UNW/quality-kit"
R="$(gate_repo)"
(cd "$R" && env PATH="$GBIN:$PATH" XDG_STATE_HOME="$UNW" FAKE_CODEX_TRANSCRIPT="$TR_ERR" FAKE_CODEX_EXIT=1 bash "$HOOK") >"$T/g11" 2>&1 \
  && ok "an unwritable log directory never blocks a commit" \
  || bad "an unwritable log directory never blocks a commit" "$(tail -3 "$T/g11")"
chmod 755 "$UNW/quality-kit" 2>/dev/null || true

# Strict mode refuses an outage, not an unreviewable diff. A structural skip is still logged,
# but blocking it would leave a strict repo unable to land an oversized diff or a plan doc at all,
# with no retry and no other reviewer that would change the answer.
R="$(gate_repo)"
run_gate "$R" "$T/g12" REVIEW_HOOK_MAX_DIFF_BYTES=1 FAKE_CODEX_EXIT=1 REVIEW_HOOK_REQUIRE_GATE=1 \
  && tail -n 1 "$GLOG" | grep -qE 'oversize_diff.*structural' \
  && ok "strict mode permits a structural skip but still records it" \
  || bad "strict mode permits a structural skip but still records it" "$(tail -3 "$T/g12")"

# A plan-only commit is advisory by design, and the advisory path must reach the log like every
# other ungated commit — a printed marker nothing records is not evidence.
R="$(gate_repo)"
(cd "$R" && mkdir -p docs/plans && git rm -q --cached f.txt && rm -f f.txt \
   && echo "# plan" > docs/plans/p.md && git add docs/plans/p.md)
run_gate "$R" "$T/g13" FAKE_CODEX_EXIT=0 \
  && grep -q "GATE_SKIPPED reason=plan_doc_advisory" "$T/g13" \
  && tail -n 1 "$GLOG" | grep -qE 'plan_doc_advisory.*structural' \
  && ok "a plan-doc advisory commit is recorded, not just announced" \
  || bad "a plan-doc advisory commit is recorded, not just announced" "$(tail -3 "$T/g13")"

# With neither XDG_STATE_HOME nor HOME set — a minimal CI image, or a sanitized git environment —
# `set -u` turns a bare $HOME fallback into an abort, and every skipped review would block the
# commit in the documented fail-open default.
R="$(gate_repo)"
(cd "$R" && env -u HOME -u XDG_STATE_HOME PATH="$GBIN:$PATH" \
   FAKE_CODEX_TRANSCRIPT="$TR_ERR" FAKE_CODEX_EXIT=1 bash "$HOOK") >"$T/g14" 2>&1 \
  && grep -q "GATE_SKIPPED reason=error" "$T/g14" \
  && ok "a skip with no HOME and no XDG_STATE_HOME still permits the commit" \
  || bad "a skip with no HOME and no XDG_STATE_HOME still permits the commit" "$(tail -3 "$T/g14")"

SUITE_COMPLETED=1
[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
