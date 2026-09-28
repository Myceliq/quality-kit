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
TOOLCHAIN_BIN := ci/oxlint-toolchain/node_modules/.bin
.PHONY: validate validate-fast
validate:
	@if [ -z "$${OXLINT_BIN:-}" ] || [ -z "$${OXFMT_BIN:-}" ]; then \
	  if [ ! -x "$(TOOLCHAIN_BIN)/oxlint" ] || [ ! -x "$(TOOLCHAIN_BIN)/oxfmt" ]; then \
	    echo "[make] toolchain missing — installing from the pinned lockfile..."; \
	    (cd ci/oxlint-toolchain && npm ci --no-audit --no-fund); \
	  fi; \
	  OXLINT_BIN="$(CURDIR)/$(TOOLCHAIN_BIN)/oxlint" OXFMT_BIN="$(CURDIR)/$(TOOLCHAIN_BIN)/oxfmt" bash bin/selftest.sh; \
	else \
	  bash bin/selftest.sh; \
	fi
validate-fast:
	@if [ -z "$${OXLINT_BIN:-}" ] || [ -z "$${OXFMT_BIN:-}" ]; then \
	  if [ ! -x "$(TOOLCHAIN_BIN)/oxlint" ] || [ ! -x "$(TOOLCHAIN_BIN)/oxfmt" ]; then \
	    echo "[make] toolchain missing — installing from the pinned lockfile..."; \
	    (cd ci/oxlint-toolchain && npm ci --no-audit --no-fund); \
	  fi; \
	  OXLINT_BIN="$(CURDIR)/$(TOOLCHAIN_BIN)/oxlint" OXFMT_BIN="$(CURDIR)/$(TOOLCHAIN_BIN)/oxfmt" bash bin/selftest.sh; \
	else \
	  bash bin/selftest.sh; \
	fi
