#!/usr/bin/env bash
# What: tests for the Bash >=4.4 version guard duplicated in every script that
#       uses a Bash 4+ feature (mapfile -d, declare -A).
# Where: quality-kit/bin.
# Why:  the guard exists so a Mac's stock Bash 3.2 fails loudly with one
#       sentence instead of a raw syntax/builtin error mid-commit (#34). A
#       broken predicate or a script that gained a 4+ feature without the
#       guard would reintroduce exactly that silent-shaped failure.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
ok()  { echo "PASS $1"; }
bad() { echo "FAIL $1: $2"; fail=1; }

# (a) The predicate as a seam: BASH_VERSINFO is readonly, so it is driven here
# via a function that takes major/minor as input rather than the real array.
check_version() {
  local major="$1" minor="$2"
  ( (( major > 4 || (major == 4 && minor >= 4) )) )
}

msg_for() {
  local major="$1" minor="$2"
  echo "quality-kit needs bash >= 4.4 (this is $major.$minor.0); macOS ships 3.2 — brew install bash"
}

if check_version 3 2; then
  bad "predicate refuses 3.2" "accepted"
else
  ok "predicate refuses 3.2"
fi

if check_version 4 3; then
  bad "predicate refuses 4.3" "accepted"
else
  ok "predicate refuses 4.3"
fi

if check_version 4 4; then
  ok "predicate accepts 4.4"
else
  bad "predicate accepts 4.4" "refused"
fi

if check_version 5 2; then
  ok "predicate accepts 5.2"
else
  bad "predicate accepts 5.2" "refused"
fi

case "$(msg_for 3 2)" in
  *"brew install bash"*) ok "message names brew install bash" ;;
  *) bad "message names brew install bash" "$(msg_for 3 2)" ;;
esac

# (b) Every file under bin/ and hooks/ (excluding *.test.sh) that uses a Bash
# 4+ feature also contains the guard string.
guard_missing() {
  local dir="$1" missing=""
  while IFS= read -r -d '' f; do
    if grep -qE 'mapfile|readarray|declare -A|local -A' -- "$f" \
      && ! grep -q 'needs bash >= 4.4' -- "$f"; then
      missing="$missing $f"
    fi
  done < <(find "$dir" -name '*.sh' -not -name '*.test.sh' -print0)
  echo "$missing"
}

missing="$(guard_missing "$ROOT/bin")$(guard_missing "$ROOT/hooks")"
if [ -z "${missing// /}" ]; then
  ok "every 4+ feature site is guarded"
else
  bad "every 4+ feature site is guarded" "unguarded:$missing"
fi

# Negative arm: strip the guard from a copy of loc-budget.sh and confirm the
# same check fails, naming the file — otherwise (b) could pass vacuously.
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/hooks"
cp "$ROOT/bin/loc-budget.sh" "$T/bin/loc-budget.sh"
sed -i '/needs bash >= 4.4/,+3d' "$T/bin/loc-budget.sh"
if grep -q 'needs bash >= 4.4' "$T/bin/loc-budget.sh"; then
  bad "negative arm setup" "guard still present after strip"
else
  neg_missing="$(guard_missing "$T/bin")"
  case "$neg_missing" in
    *loc-budget.sh*) ok "negative arm: missing guard is caught, naming the file" ;;
    *) bad "negative arm: missing guard is caught, naming the file" "got:$neg_missing" ;;
  esac
fi

echo "bash-floor: done, $fail failed"
exit "$fail"
