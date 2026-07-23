# quality-kit

Fleet validation standard. Stamp it into a repo with
`bin/stamp.sh <repo> --profile <nextjs|vite|node|python>`; the repo's CI runs
`bin/check-drift.sh` against this kit at the repo's pinned version tag
(`quality-kit-v<VERSION>`), then runs the repo's own `validate`.

Spec: `docs/specs/2026-07-17-quality-platform-design.md`.

## .quality-kit.json (written into each stamped repo)

    {
      "version": "0.2.0", "profile": "nextjs", "runner": "npm", "pendingFlags": [],
      "ruleOverrides": {
        "burnDown":  { "func-style": 143 },
        "permanent": { "import/no-default-export": { "level": "off", "why": "Next.js pages require default exports" } }
      },
      "ignoreOverrides": ["src/generated/**"]
    }

- `version` — kit pin; CI checks out tag `quality-kit-v<version>`.
- `profile` — which kit shape is stamped. `runner` — `npm` or `make`.
- `pendingFlags` — tsconfig strict flags a repo may temporarily override to
  `false` while burning down errors (sanctioned staging; drift-visible).
- `ruleOverrides.burnDown` — `rule → allowed violation count`, generated on
  first stamp by `bin/baseline-rules.sh`. Applied at `warn` on TS profiles
  (visible, non-blocking); `extend-ignore`d on python, since ruff has no warn
  severity. `check-drift.sh --ratchet` re-counts every CI run: counts may only
  shrink, and an entry that reaches zero must be removed.
- `ruleOverrides.permanent` — `rule → {level, why}`, never generated. `level` is
  `off` or `warn` (python: `off` only). A non-empty `why` is enforced.
- `ignoreOverrides` — repo-specific ignore globs appended to the fleet preset's.

Rule ids use **config form**, not diagnostic form: core eslint rules are bare
(`func-style`), everything else is `plugin/rule` (`unicorn/filename-case`).
`bin/baseline-rules.sh` normalizes oxlint's `plugin(rule)` diagnostics for you.

Everything except `version` / `profile` / `runner` is repo-owned and survives a
re-stamp byte-exact.

## Rule overrides — how they are enforced

- **Static** (`check-drift.sh <repo>`, toolchain-free, runs before install):
  schema — shapes, non-empty `why`, no rule in both sections, valid levels,
  positive integer counts.
- **Ratchet** (`check-drift.sh <repo> --ratchet`, runs after install): the real
  counting pass, wired into the stamped `quality.yml` as a post-install step.
- **Fail-closed on unknown rule keys.** The static check validates shape, not
  whether a rule id exists. A typo'd or removed-in-upgrade rule in `burnDown` /
  `permanent` is a hard oxlint config-parse error (`Rule '...' not found`,
  exit 1) at lint time — not a silent no-op.

## Stamping a repo — known gotchas

Hit during the mentzer-method pilot (Wave 1). Check these before opening the
stamp PR — most of them BLOCK a green stamp.

- **`.claude/` gitignored.** The stamp writes `.claude/settings.json` (Stop +
  PostToolUse hooks); a repo that ignores all of `/.claude/` never commits it,
  so the drift gate fails (`… lost or altered the kit … hook`). Carve it out —
  `/.claude/*` then `!/.claude/settings.json` — and commit the file.
- **Regenerated lock vs strict `npm ci`.** Adding the kit devDeps + regenerating
  `package-lock.json` can surface a pre-existing peer conflict the old lock had
  absorbed (mentzer: `openapi-typescript` ✗ `typescript@7`). `npm install` is
  lenient; CI's `npm ci` is strict → ERESOLVE. Reconcile via npm `overrides` or
  a compatible bump (respect the repo's `.npmrc`); confirm a clean `npm ci`
  before the PR.
- **First stamp commit can't pass the local hook.** Once `.quality-kit.json`
  exists, the global pre-commit runs `validate:fast`, which can't be green
  pre-burn-down. Commit the initial stamp from a context without the kit hook
  (or via `git commit-tree`). This is the one bootstrap exception — never
  `--no-verify` on the burn-down work itself.
- **codex may false-flag the TS7 pin.** The pre-commit heuristic flags
  `typescript@7.0.2` as "outside the lint peer range". Benign —
  `oxlint-tsgolint` is the TS-Go-native linter, built for TS7.
- **`.github/**` edits trip protected-path.** On repos under the F1 ruleset the
  stamp PR (and every strict-flag burn-down PR) needs a one-time owner override.
- **Blast radius is large on mature repos.** Expect big counts (mentzer: ~1.6k
  tsc, ~9.9k oxlint). Stage the 3 high-blast tsconfig flags via `pendingFlags`
  and burn down incrementally — do NOT fix everything before the first green
  merge.
- **First stamp needs the toolchain installed to seed the burn-down.** Generation
  runs the repo's real linter. Stamping before `npm ci` (or without ruff on PATH)
  leaves `ruleOverrides.burnDown` empty and prints the follow-up command — the
  stamp still succeeds, but CI will be red until you run
  `quality-kit/bin/baseline-rules.sh <repo>` and commit the result. On the python
  profile, re-run `bin/stamp.sh` afterwards rather than editing `ruff.toml`: that
  file is rendered from the burn-down, and the drift gate compares it against a
  fresh render.
- **The first `.quality-kit.json` diff is large, and that is correct.** A mature
  repo seeds one burn-down entry per failing rule (mentzer: ~85 rules / ~2.5k
  violations). Reviewers should read it as an inventory of accepted debt, not as
  weakening — every entry is counted, ratcheted, and must reach zero. Do not trim
  it by hand to look smaller; a count lower than reality fails the ratchet on the
  very next CI run.

## Releasing

Bump `VERSION`, merge to main, tag `quality-kit-v<VERSION>` on the merge
commit, push the tag. Repos upgrade by re-running stamp.sh (new PR).

## python-profile CI gap (v1)

Repos stamped with `--profile python` get **no stamped CI workflow** in v1 —
the drift gate + validate CI for python lands with Wave 3. Until then, python
enforcement is local-only: pre-commit `validate-fast` + the companion
post-run gate + the stamped local tooling. This is a deliberate, documented
gap, not an oversight.
