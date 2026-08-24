# quality-kit

Fleet validation standard. Stamp it into a repo with
`bin/stamp.sh <repo> --profile <nextjs|vite|node|python>`; the repo's CI runs
`bin/check-drift.sh` against this kit at the repo's pinned version tag
(`quality-kit-v<VERSION>`), then runs the repo's own `validate`.

This repo is **public** for one reason: a stamped repo's CI checks it out by
tag, and a workflow's built-in `GITHUB_TOKEN` cannot check out a *private*
repo other than its own. While the kit lived inside the private `cockpit`
repo, every stamped repo needed its own hand-minted fine-grained PAT — manual
browser work per repo, with no API to automate it, and that was the binding
constraint on fleet-wide adoption. Public removes it. Nothing here is secret:
it is lint configs, shell scripts and a stamper.

Design spec lives in the private cockpit repo
(`docs/specs/2026-07-17-quality-platform-design.md`).

## The global pre-commit gate

`hooks/git-pre-commit` is the per-commit Codex review gate. Unlike everything
under `ts/` and `py/`, it is **not** stamped into repos — it is installed once
per machine as the global hook (`git config --global core.hooksPath`), so
changing it here does not move any repo's pinned version.

Its verdict parsing lives in `codex_verdict()`, deliberately split out and
reachable via `CODEX_HOOK_LIB_ONLY=1` so it can be tested directly. **Findings
are matched before any approval signal**, and every case in
`hooks/git-pre-commit.test.sh` is a commit that really did pass while the hook
printed success. Read the comments there before widening a regex — two of them
document gaps that are deliberate, where the obvious "fix" reopens a hole.

`hooks/hooks-doctor.sh <workspace-root>` answers the question nothing else on a
box can: *is the gate actually live here?* A repo-local `core.hooksPath`
silently overrides the global one, and git skips a hooks directory with no
`pre-commit` without any error at all — so an ungated repo looks exactly like a
gated one. It reports `OK` / `STALE` / `GATE-OFF` / `ORPHAN` per repo and exits
non-zero if any live repo is ungated.

## The stamped Codex hooks (`.codex/hooks.json`)

The stamp writes `.codex/hooks.json` — a `PostToolUse` formatter and a `Stop`
gate that runs `.quality/stop-validate.sh` at turn end. **Stamping the file is
not enough to make it run.** Codex applies two independent trust gates, and
each drops the hooks *silently*: no warning on the run, nothing in the
transcript, so a stamped-but-inert repo looks exactly like a gated one.

1. **The project must be trusted.** A project's `.codex/` config layer is
   discarded at load unless that project is trusted in the user's own Codex
   config — in `~/.codex/config.toml`:

       [projects."<path>"]
       trust_level = "trusted"

   and `hooks.json` is only read from layers that
   survived the load — so an untrusted project has no hooks at all. Codex's
   interactive TUI asks "do you trust this folder?" the first time it opens
   one; the non-interactive runner grants and persists the same trust by
   itself *when the sandbox already permits writing the working directory*.
   Under a read-only sandbox, or against an explicit
   `trust_level = "untrusted"`, the hooks never load.
2. **Each hook must be approved once.** Even inside a trusted project, a hook
   Codex has not seen before counts as untrusted and does not run until it is
   approved in the TUI's hooks browser (which records its hash under
   `[hooks.state]`) or the invocation opts out of the review with
   `--dangerously-bypass-hook-trust`. Re-stamping a *changed* `hooks.json`
   changes that hash and needs a fresh approval.

So on a freshly stamped repo the Codex-side turn-end gate is **off** until
someone has opened that repo in Codex once and approved the hooks. Confirm it
rather than assuming; the same `.quality/stop-validate.sh` also hangs off the
`Stop` hook in `.claude/settings.json`, which has no trust gate, so one agent's
side can be gated while Codex's is inert. The kit never reads or writes
`~/.codex/config.toml` — granting trust is the operator's call, on their own
machine.

Trust is keyed by path, so a second *clone* of the same repo needs its own
entry. Linked git worktrees do not: Codex resolves a worktree to its main
checkout before looking up trust, and reads the **main checkout's**
`.codex/hooks.json` rather than the worktree's — which also means a `hooks.json`
edited on a branch inside a worktree does not take effect there.

## .quality-kit.json (written into each stamped repo)

    {
      "version": "0.2.0", "profile": "nextjs", "runner": "npm", "pendingFlags": [],
      "ruleOverrides": {
        "burnDown":  { "func-style": 143 },
        "permanent": { "import/no-default-export": { "level": "off", "why": "Next.js pages require default exports" } }
      },
      "ignoreOverrides": ["src/generated/**"],
      "locBudget": { "budget": 5000, "paths": ["src/**", "scripts/*.sh"] }
    }

- `version` — kit pin; CI checks out tag `quality-kit-v<version>`.
- `profile` — which kit shape is stamped. `runner` — `npm` or `make`.
- `pendingFlags` — tsconfig strict flags a repo may temporarily override to
  `false` while burning down errors (sanctioned staging; drift-visible).
- `ruleOverrides.burnDown` — `rule → allowed violation count`, generated on
  first stamp by `bin/baseline-rules.sh`. Applied at `warn` on TS profiles
  (visible, non-blocking); `extend-ignore`d on python, since ruff has no warn
  severity. `check-drift.sh --ratchet` re-counts every CI run: counts may only
  shrink, and an entry that reaches zero must be removed. A count can be
  raised — a justified, diff-visible bump in `.quality-kit.json` — if new
  violations are genuinely unavoidable.
- `ruleOverrides.permanent` — `rule → {level, why}`, never generated. `level` is
  `off` or `warn` (python: `off` only). A non-empty `why` is enforced.
- `ignoreOverrides` — repo-specific ignore globs appended to the fleet preset's.
- `locBudget` — optional. `bin/loc-budget.sh <repo>` fails when tracked source
  under `paths` (git pathspecs) exceeds `budget`, counting language-aware SLOC
  (blank lines, comments, and Python docstrings are free). `LOC_PATHS` /
  `LOC_BUDGET` env vars override this block; the block is the repo-committed
  default. Neither source configured is a loud refusal, not a
  default-everything sweep — sweeping the whole tree would silently count
  vendored/generated code. Not wired into stamped CI in v1; run it as an
  explicit CI step or locally.

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
  exit 1) at lint time — not a silent no-op. (Verified for oxlint/TS profiles;
  a typo'd ruff code may behave differently — not verified.)

## Stamping a repo — known gotchas

Hit during the mentzer-method pilot (Wave 1). Check these before opening the
stamp PR — most of them BLOCK a green stamp.

- **The stamped `.codex/hooks.json` does not run until Codex trusts the repo.**
  Both of Codex's trust gates skip hooks silently, so the stamp looks complete
  while the turn-end gate is off. See "The stamped Codex hooks" above.
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
- **nextjs profile floors `next` at 16.3.1, and the drift gate enforces it.**
  Anything older **segfaults** in `next build` under `CI=1` against the pinned
  `typescript@7` (measured: 16.2.4 → exit 139/134, deterministic; 16.3.1 → exit 0
  and it type-checks with TS7). Both halves of the failure are invisible: a local
  build sees TS7 as missing, quietly `npm install`s its own TypeScript and goes
  green, while the CI log ends at `Command "npm run build" exited with 1` naming
  neither TypeScript nor a signal. Fix with `npm install next@latest` and commit
  the lockfile. The gate reads `package-lock.json`, not the `package.json` range —
  `npm ci` installs the lock, so a conforming `^16.3.1` over a stale lock still
  ships the segfault. Do **not** reach for `typescript: { ignoreBuildErrors: true }`:
  on a current Next it suppresses a check that works.
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

**The tag is the release.** A version that is merged but never tagged looks
shipped and is not: stamped repos resolve `quality-kit-v<version>` and their
CI fails at checkout. This has already happened once (v0.3.0). Before telling
anyone a version exists, confirm `git rev-list -n1 quality-kit-v<version>`.

## python-profile CI gap (v1)

Repos stamped with `--profile python` get **no stamped CI workflow** in v1 —
the drift gate + validate CI for python lands with Wave 3. Until then, python
enforcement is local-only: pre-commit `validate-fast` + the companion
post-run gate + the stamped local tooling. This is a deliberate, documented
gap, not an oversight.
