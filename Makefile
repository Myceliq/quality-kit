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
.PHONY: validate validate-fast
validate:
	@bash bin/selftest.sh
validate-fast:
	@bash bin/selftest.sh
