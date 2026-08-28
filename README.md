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
reachable via `REVIEW_HOOK_LIB_ONLY=1` so it can be tested directly. **Findings
are matched before any approval signal**, and every case in
`hooks/git-pre-commit.test.sh` is a commit that really did pass while the hook
printed success. Read the comments there before widening a regex — two of them
document gaps that are deliberate, where the obvious "fix" reopens a hole.

### When the review does not run

Every path that reaches a commit without a completed review now prints
`[codex-hook] GATE_SKIPPED reason=<reason>` and appends one tab-separated line to
`${XDG_STATE_HOME:-~/.local/state}/quality-kit/gate-skips.log`
(timestamp, reason, repo, branch, class). Before this, a skip was one
human-readable sentence in the commit output, so nothing downstream could tell
*reviewed and clean* from *never ran* — and in an agent-driven repo nobody reads
the sentence.

Reasons are classified into two kinds, because they want different answers:

| class | reasons | what it means |
|---|---|---|
| `provider_failure` | `codex_unavailable`, `usage_limit`, `sandbox_init`, `timeout`, `empty_output`, `error` | the review was **unavailable**. Retrying later works. |
| `structural` | `oversize_diff`, `oversize_plan_diff`, `plan_doc_advisory` | the diff is **not reviewable in this form**. No retry rescues it. |

`usage_limit` and `sandbox_init` are separate reasons on purpose: neither is
transient. Usage exhaustion persists until the quota resets and a sandbox that
cannot initialise recurs on every commit until the environment is fixed, so in
both cases the gate is *reliably* absent while continuing to look installed.
Folded into a generic error, they needed a human to notice rather than a count.

**The default still permits the commit.** To refuse one instead, set
`REVIEW_HOOK_REQUIRE_GATE=1`, or put `"requireGate": true` in
`.quality-kit.json` so the setting travels with the repo and survives a fresh
clone or a CI runner that never sourced anyone's profile. An explicit
environment variable wins over the stamped value, so a deliberate one-off
remains possible.

Strict mode refuses an **outage**, not an unreviewable diff: only
`provider_failure` blocks. Structural skips are still logged, but blocking them
would leave a strict repo unable to land an oversized diff or a plan doc at all,
and no retry or alternative reviewer would change the answer.

Knobs are read as `REVIEW_HOOK_<NAME>` first and `CODEX_HOOK_<NAME>` second
(`LIB_ONLY`, `MAX_DIFF_BYTES`, `MODEL`, `REASONING_EFFORT`, `REQUIRE_GATE`,
`TIMEOUT_SECONDS`), with a one-line notice when the legacy name is what supplied
the value. The names match the multi-provider fork of this hook so a stamped
fleet migrates once rather than twice; the old names keep working until every
call site has moved.

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
   config — in `$CODEX_HOME/config.toml`, where `$CODEX_HOME` defaults to
   `~/.codex`:

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
`$CODEX_HOME/config.toml` — granting trust is the operator's call, on their own
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
- `requireGate` — optional. `true` refuses any commit whose pre-commit review
  did not run (see *When the review does not run*). Lives here rather than only
  in the environment so it survives a fresh clone; an explicit
  `REVIEW_HOOK_REQUIRE_GATE` still overrides it.
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
- **The ts profiles floor Node at 22.12.0, and the drift gate enforces it.**
  The pinned toolchain sets that floor: oxlint/oxfmt/Vite (and all their platform
  bindings) declare `^20.19.0 || >=22.12.0`, and `ultracite` pulls `commander@15`
  at a flat `>=22.12.0` with **no Node 20 branch** — so the intersection is
  22.12.0, roughly two majors above what Next alone asks for. On Node 20.9–20.18
  `npm run validate` dies on the *runtime* before it reads any code, and with
  `engine-strict` the install itself fails; neither failure names Node. The
  stamped `quality.yml` runs Node 24, so **CI never sees this** — only a developer
  or a delegate on an older Node does. `stamp.sh` writes
  `engines: { "node": ">=22.12.0" }` into `package.json`, and the gate fails the
  repo if the declared range admits anything older. Note `^20.19.0 || >=22.12.0`
  copied off oxlint does **not** satisfy it: `||` is OR, so that range still
  admits Node 20.19. A *stricter* floor (`>=24`) is yours to keep — a re-stamp
  never lowers one. The range parser is deliberately narrow (`>=`, `^`, `~`,
  `=`, exact, x-ranges, combined with spaces and `||`); anything else —
  hyphen ranges, `v`-prefixes, prereleases, build metadata, a strict `>`, two
  lower bounds in one branch — is **refused, not guessed at**, with a message
  naming what to write instead. A range whose bounds admit no Node at all
  (`>=22.12.0 <22.12.0`) is reported as unsatisfiable.
- **A stamped repo must have at least one test file, and the drift gate enforces
  it.** `test:unit` is in the canonical `validate` chain, and both runners treat
  an empty collection as a failure — `vitest run` exits 1, `pytest` exits 5 and
  `make` propagates it — so a repo stamped with no tests is **red on day one**,
  for a reason its own build log explains badly. The gate matches the runner's
  real collection rules — including each runner's own exclusions, plus every
  dotted directory so the kit's in-repo `.quality-kit-src` checkout is never
  counted. On the ts profiles that is vitest's default include
  `**/*.{test,spec}.?(c|m)[jt]s?(x)` **and** a *bound* suite declaration inside
  it: a matching file that declares none is collected and then fails with `No
  test suite found in file`, which is the same red. Bound matters — vitest's
  `globals` default is **false**, so `it` / `test` / `describe` / `suite` /
  `bench` must be imported from `vitest` (named, aliased, or as a namespace)
  unless your vitest config sets `test.globals: true`; a bare `it(...)` with no
  import throws `it is not defined` at run time. On python it is pytest's default
  `test_*.py` / `*_test.py` **and** a real item inside it — a top-level `test*`
  function, or a `test*` method on a top-level `Test*` class or any
  `unittest.TestCase` subclass — checked against the file's AST rather than by
  grep. pytest imports a matching module and still exits 5 if it declares no
  item, so neither a helper named `test_helpers.py`, nor `class TestHelpers:
  pass`, nor a `test_x` method on a plain non-`Test*` class satisfies the gate.
  Fix it by writing a test — `src/smoke.test.ts` or `tests/test_smoke.py`. A
  repo that configures its runner's collection away from the defaults (a
  `test.include` in a vitest config, `python_files` / `testpaths` in a pytest
  config) gets an explicit hand-off instead: the gate cannot evaluate those
  rules before install, says so on stderr, and leaves the guarantee to the
  repo's own `validate` run. Do **not** reach for `vitest run --passWithNoTests`:
  it turns the repo green by deleting the requirement rather than meeting it,
  and would go on silently absorbing a later misconfiguration that stops
  collecting the tests you do have.
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
