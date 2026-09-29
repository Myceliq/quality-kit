# What: the kit repo's single self-gate command. Where: the repo root.
# Why:  the factory engine's existing `make` row invokes exactly `make validate`
#       (its four-key _RUNNER_ARGV reads only the `runner` key of
#       .quality-kit.json), so this target IS the gate — it must run the same
#       command CI runs (tests.yml: toolchain install, then bash
#       bin/selftest.sh), not a subset of it. `validate` is the target the
#       engine asks for; this file exists so it has something to ask.
# `validate-fast` is the same recipe, not a subset: the box's pre-commit hook and
# the turn-end stop hook both invoke `make validate-fast` for a make-runner repo,
# and the kit's own stamped python profile defines the two as identical lines
# (py/Makefile.quality). A fast/full split would belong to a future stamp.
#
# The recipe resolves its own toolchain (#55): a factory run's commit path (hook →
# make validate-fast) never exports OXLINT_BIN/OXFMT_BIN, and run 1 failed
# implement-no-commit with every commit rejected at the hook for exactly that.
# Pre-set vars win — a caller that already exported them (CI's tests.yml) skips
# the install entirely; otherwise the pinned lockfile in ci/oxlint-toolchain is
# installed with the same `npm ci` CI runs. The guard in selftest.sh is FED, not
# bypassed: invoking selftest.sh directly without the vars still refuses.
# Two review findings shaped this recipe (PR #56): a failed `npm ci` must be
# terminal (`|| exit 1` — make recipes run without `-e`, so a bare `;` would
# proceed to export paths at bins that were never installed and misdiagnose),
# and a PARTIAL preset (one var set, one unset) keeps the preset var rather
# than overwriting both (`${VAR:-default}` per var, not an either/or branch).
# The install check is PAIRED per tool (CR #56 r2): install iff (var unset AND
# local bin missing) for the SAME tool — a preset tool whose local bin is absent
# must never trigger `npm ci`, or validation fails offline to install a bin
# nobody will use.
# #72: vitest (installed into the same toolchain by #69) is resolved exactly like
# oxlint/oxfmt — a VITEST_BIN the suites read, preset-wins, paired install check —
# so a checkout whose node_modules predates #69 (oxlint/oxfmt present, vitest
# absent) reinstalls instead of running the vitest suites against nothing.
# One rule for both targets: two copies of this recipe had to be edited in
# lockstep, and a drift between them is a gate that differs by entry point.
TOOLCHAIN_BIN := ci/oxlint-toolchain/node_modules/.bin
.PHONY: validate validate-fast
validate validate-fast:
	@if ([ -z "$${OXLINT_BIN:-}" ] && [ ! -x "$(TOOLCHAIN_BIN)/oxlint" ]) || ([ -z "$${OXFMT_BIN:-}" ] && [ ! -x "$(TOOLCHAIN_BIN)/oxfmt" ]) || ([ -z "$${VITEST_BIN:-}" ] && [ ! -x "$(TOOLCHAIN_BIN)/vitest" ]); then \
	  echo "[make] toolchain missing — installing from the pinned lockfile..."; \
	  (cd ci/oxlint-toolchain && npm ci --no-audit --no-fund) || exit 1; \
	fi; \
	OXLINT_BIN="$${OXLINT_BIN:-$(CURDIR)/$(TOOLCHAIN_BIN)/oxlint}" OXFMT_BIN="$${OXFMT_BIN:-$(CURDIR)/$(TOOLCHAIN_BIN)/oxfmt}" VITEST_BIN="$${VITEST_BIN:-$(CURDIR)/$(TOOLCHAIN_BIN)/vitest}" bash bin/selftest.sh
