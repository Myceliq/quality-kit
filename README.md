# quality-kit

Fleet validation standard. Stamp it into a repo with
`bin/stamp.sh <repo> --profile <nextjs|vite|node|python>`; the repo's CI runs
`bin/check-drift.sh` against this kit at the repo's pinned version tag
(`quality-kit-v<VERSION>`), then runs the repo's own `validate`.

Spec: `docs/specs/2026-07-17-quality-platform-design.md`.

## .quality-kit.json (written into each stamped repo)

    {"version": "0.1.0", "profile": "nextjs", "runner": "npm", "pendingFlags": []}

- `version` — kit pin; CI checks out tag `quality-kit-v<version>`.
- `profile` — which kit shape is stamped. `runner` — `npm` or `make`.
- `pendingFlags` — tsconfig strict flags a repo may temporarily override to
  `false` while burning down errors (sanctioned staging; drift-visible).

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

## Releasing

Bump `VERSION`, merge to main, tag `quality-kit-v<VERSION>` on the merge
commit, push the tag. Repos upgrade by re-running stamp.sh (new PR).

## python-profile CI gap (v1)

Repos stamped with `--profile python` get **no stamped CI workflow** in v1 —
the drift gate + validate CI for python lands with Wave 3. Until then, python
enforcement is local-only: pre-commit `validate-fast` + the companion
post-run gate + the stamped local tooling. This is a deliberate, documented
gap, not an oversight.
