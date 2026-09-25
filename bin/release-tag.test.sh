#!/usr/bin/env bash
# What: tests for release-tag.sh. Where: quality-kit/bin.
# Why:  this is the only tested part of the tag-on-merge workflow (#deploy-drift
#       task 7) — the workflow itself just shells out to this and acts on its
#       verdict, so every create/skip/invalid decision has to be right here,
#       off GitHub, where a mistake costs a CI run instead of a moved tag.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
RT="$DIR/release-tag.sh"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }

tagsfile() { local f; f="$(mktemp)"; printf '%s\n' "$@" > "$f"; echo "$f"; }

# --- absent tag: create ---
T="$(tagsfile quality-kit-v0.5.3 quality-kit-v0.5.2)"
rc=0; out="$(bash "$RT" 0.5.4 "$T")" || rc=$?
[ "$rc" = 0 ] && [ "$out" = create ] && ok "absent tag creates" || bad "absent tag creates" "rc=$rc out=$out"

# --- present tag: skip ---
T="$(tagsfile quality-kit-v0.5.4 quality-kit-v0.5.3)"
rc=0; out="$(bash "$RT" 0.5.4 "$T")" || rc=$?
[ "$rc" = 0 ] && [ "$out" = skip ] && ok "present tag skips" || bad "present tag skips" "rc=$rc out=$out"

# --- short version "1.2": invalid ---
T="$(tagsfile)"
rc=0; out="$(bash "$RT" 1.2 "$T")" || rc=$?
[ "$rc" = 1 ] && [ "$out" = invalid ] && ok "short version invalid" || bad "short version invalid" "rc=$rc out=$out"

# --- pre-release "1.2.3-rc1": invalid ---
T="$(tagsfile)"
rc=0; out="$(bash "$RT" 1.2.3-rc1 "$T")" || rc=$?
[ "$rc" = 1 ] && [ "$out" = invalid ] && ok "pre-release suffix invalid" || bad "pre-release suffix invalid" "rc=$rc out=$out"

# --- leading zero "01.2.3": invalid (semver forbids leading zeros) ---
T="$(tagsfile)"
rc=0; out="$(bash "$RT" 01.2.3 "$T")" || rc=$?
[ "$rc" = 1 ] && [ "$out" = invalid ] && ok "leading zero invalid" || bad "leading zero invalid" "rc=$rc out=$out"

# --- a lone zero component is valid, unlike a leading zero ---
T="$(tagsfile)"
rc=0; out="$(bash "$RT" 0.5.4 "$T")" || rc=$?
[ "$rc" = 0 ] && [ "$out" = create ] && ok "lone zero component valid" || bad "lone zero component valid" "rc=$rc out=$out"

# --- empty tags file (repo's very first release): create ---
T="$(tagsfile)"
rc=0; out="$(bash "$RT" 0.1.0 "$T")" || rc=$?
[ "$rc" = 0 ] && [ "$out" = create ] && ok "no tags yet creates" || bad "no tags yet creates" "rc=$rc out=$out"

# --- exact-line match only: a tag that merely CONTAINS the target as a substring must not skip it ---
T="$(tagsfile quality-kit-v0.5.40 xquality-kit-v0.5.4)"
rc=0; out="$(bash "$RT" 0.5.4 "$T")" || rc=$?
[ "$rc" = 0 ] && [ "$out" = create ] && ok "substring tag match does not skip" || bad "substring tag match does not skip" "rc=$rc out=$out"

[ "$fail" = 0 ] && echo "ALL PASS" || { echo FAILURES; exit 1; }
