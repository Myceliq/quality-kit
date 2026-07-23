<!-- quality-kit:begin -->
## Quality gates (quality-kit — stamped, do not edit this section by hand)

Validation contract, identical local and CI (`npm run` / `make` per this repo's
`.quality-kit.json` runner):

- `validate` — full gate: format:check → lint → typecheck → unit tests → repo
  extras → build. CI runs exactly this.
- `validate:fast` (make: `validate-fast`) — repair loop: format:check → lint →
  typecheck → affected tests. Run after EVERY implementation attempt and
  before reporting done. Hooks and pre-commit run it for you; delegates
  without hooks must run it themselves.

Rules (CI drift gate enforces these — a PR that violates them cannot merge):

- Never edit stamped files (`.quality/`, `oxlint.config.ts`, `oxfmt.config.ts`,
  `tsconfig.quality.json`, `.github/workflows/quality.yml`, `.codex/hooks.json`;
  python profile: `ruff.toml`, `pyrightconfig.json`, `Makefile.quality`).
  Change cockpit `quality-kit/` and re-stamp instead.
- Never add lint/type suppressions (`oxlint-disable`, `@ts-expect-error`,
  `@ts-ignore`, `noqa`, `type: ignore`) to get green. A genuinely needed one =
  bump `.quality/suppression-baseline.json` in the same PR and justify it in
  the PR body.
- Never relax tsconfig strict flags. Sanctioned staging lives ONLY in
  `.quality-kit.json` `pendingFlags`.
- Never edit `oxlint.config.ts` / `ruff.toml` to silence a rule. The only
  sanctioned outlet is `.quality-kit.json` `ruleOverrides`, edited in the same
  PR as the code it covers:
  - `burnDown` (`rule → count`) — a temporary, counted allowance. CI re-counts
    every run: the count may only shrink, and when it reaches zero the entry
    must be removed. If new violations are genuinely unavoidable, the
    sanctioned path is to raise that rule's count in `.quality-kit.json` in
    the same PR (a diff-visible, reviewed bump, justified in the PR body) —
    the same kind of sanctioned staging as `pendingFlags`. Writing a
    justification without raising the count does not pass the ratchet.
  - `permanent` (`rule → {level, why}`) — a rule that genuinely never fits this
    repo. `level` is `off` or `warn` (python: `off` only — ruff has no warn
    severity). `why` is required and must say what makes the rule wrong here,
    not that it was inconvenient.
  - `ignoreOverrides` — repo-specific ignore globs (generated dirs, vendored
    code), appended to the fleet preset's patterns.
- Never delete or skip tests to get green.
- Evidence before claiming progress: paste the tail of the passing validate
  output. If a check doesn't exist yet, say that plainly — don't fake it.
<!-- quality-kit:end -->
