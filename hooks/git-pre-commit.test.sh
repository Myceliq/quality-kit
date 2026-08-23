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

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
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
CODEX_HOOK_LIB_ONLY=1 . "$HOOK"

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

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
