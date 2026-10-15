# Rust profile: design

Date: 2026-10-15. Status: decisions approved in conversation; spec awaiting review.
First consumer: `thomaslestum/rift-sidekick` (Cargo workspace: a Tauri v2 app crate and a CLI crate).

## Goal

`bin/stamp.sh <repo> --profile rust` gives a Cargo repo the same guarantees the python and TypeScript profiles give theirs: one `validate` contract run by the turn-end hook, the pre-commit gate and CI; byte-owned configs checked for drift at a pinned kit version; the existing burn-down ratchet, where counts shrink and any increase is an explicit, reviewable change in `.quality-kit.json`.

## Decisions

| Question | Decision |
|---|---|
| Model | The python profile: `runner = make`, a stamped `Makefile.quality` included from the repo's `Makefile`, no package-manager detection |
| Docstrings | Enforced for all items that compile on the CI host (see the coverage limit under Lint levels): rustc `missing_docs` and `clippy::missing_docs_in_private_items`, both seeded into the existing burn-down (`ruleOverrides.burnDown`), so day one is green and the count only shrinks. First docstring gate in the kit |
| Supply chain | `cargo deny check` (advisories, bans, licenses, sources) with a stamped `deny.toml`, and `cargo shear` for unused dependencies. First dependency gate in the kit |
| CI | Stamped `.github/workflows/quality.yml`, one Linux job, same step order as the TS workflows; installs the WebKit/GTK packages a Tauri crate needs when the workspace depends on `tauri` |
| Toolchain | Stable only; locked mode on every command that resolves dependencies (`--locked` for cargo build/test/doc/clippy/deny; `cargo fmt` takes none); tools installed in CI with pinned versions |

## The validate contract

| Target | Commands | In `validate-fast` (turn end) |
|---|---|---|
| `format-check` | `cargo fmt --all --check` | yes |
| `lint` | `cargo clippy --workspace --all-targets --all-features --locked` with warnings denied | yes |
| `typecheck` | covered by `lint` (clippy type-checks); target kept as an alias so the contract's names match the other profiles | yes |
| `spell` | `typos` | yes |
| `test-unit` | `cargo nextest run --workspace --locked`, then `cargo test --doc --workspace --locked` (nextest does not run doctests) | no |
| `docs` | `cargo doc --no-deps --workspace --locked` with rustdoc warnings denied | no |
| `deps` | `cargo deny --workspace --locked check` (`--workspace` so every member of a non-virtual workspace is covered), `cargo shear --locked --deny-warnings` (plain `cargo shear` exits 0 on warning-class findings and does not forward locking to `cargo metadata`) | no |
| `validate` | all of the above | |

`validate-fast` drops the minutes-scale and network targets, unlike python where both are identical; a warm clippy is seconds, a cold one is not, which the turn-end hook already tolerates for TS builds.

## Lint levels

Set as a `[workspace.lints]` table that the stamp renders from the kit's base levels plus the repo's `.quality-kit.json` overrides (as `bin/render-ruff.sh` does for python) and merges into the root `Cargo.toml`; drift compares it with a fresh render. `[workspace.lints]` is not inherited automatically: the stamp also adds `[lints] workspace = true` to every member's `Cargo.toml`, and drift fails any member without it (https://doc.rust-lang.org/cargo/reference/workspaces.html#the-lints-table). Baseline:

- clippy default groups at their defaults, warnings denied;
- `clippy::pedantic` at warn, with a short kit-owned allow list for known-noisy lints (each with a reason);
- restriction lints chosen for agent-written code (`dbg_macro`, `todo`, `unwrap_used` outside tests, `allow_attributes_without_reason`), each verified against the current lint index before it is listed;
- `missing_docs`, `clippy::missing_docs_in_private_items` (docstring gate above);
- `unsafe_code = "forbid"` unless the repo records a permanent override with a reason.

Existing violations of any of these at stamp time go to `burnDown`, counted per lint from `cargo clippy --message-format=json`; as in the other profiles, a count shrinks, and raising one is a visible change in the PR. Because `validate` denies warnings, a burn-down lint is rendered as `allow` in the table (the python profile's `extend-ignore` pattern, not the TS `warn` pattern); the ratchet re-enables each one with `-W <lint>` only while counting.

Coverage limit: lints see what compiles on the CI host (Linux, all features). Code behind `cfg(windows)` or `cfg(target_os = "macos")` is linted only where a repo runs clippy on that OS; the kit's CI is Linux-only, so such repos keep a repo-owned job per extra OS (rift-sidekick already has a Windows test job and adds clippy to it).

## Kit changes

| Area | Change |
|---|---|
| `rust/` (new) | `Makefile.quality`, `rustfmt.toml`, `clippy.toml`, `deny.toml`, `_typos.toml`, `quality.yml` (CI), lint table source |
| `bin/stamp.sh` | `rust` in the profile list and usage; `put` branch: runner make, Makefile include, byte-owned copies, lint-table merge, burn-down and suppression seeding; widen the `!= python` package-manager guards to "TS profiles only" |
| `bin/check-drift.sh` | a third profile branch wherever it now splits python/TS: byte-owned `same` checks, opposite-profile exclusion, permanent-override levels, no source-level test-file check: a `#[test]` grep cannot prove a runnable test exists, and nextest already fails a run that collects zero tests (https://nexte.st/docs/running/), which gives the same red-on-day-one signal as vitest and pytest, ratchet toolchain check (`cargo`, `clippy-driver`) |
| `bin/baseline-rules.sh` | rust branch: count clippy/rustc lint hits per rule from JSON output |
| `bin/count-suppressions.sh` | count `#[allow(`, `#![allow(`, `#[expect(`, `unsafe` in `*.rs` |
| `hooks/format-changed.sh` | `*.rs` → `rustfmt` (shared byte-owned file: moves every profile's pin, called out in the release notes) |
| `agents/QUALITY.md` | rust stamped-files list and suppression rules |
| Tests | `bin/stamp.test.sh`, `bin/check-drift.test.sh` and `bin/selftest.sh` gain rust fixtures (a two-crate workspace) |
| `README.md` | profile list, rust notes |

## Rollout

1. Kit PR with the profile, released as a minor version (`VERSION` 0.8.0, auto-tagged).
2. Stamp rift-sidekick in its own PR: burn-down seeded from today's code, `validate` green, the repo's Windows test job kept as a repo-owned extra workflow.

## Risks

- Pedantic and docstring lints produce large initial burn-down counts on existing code; acceptable by design, they only shrink.
- `cargo deny` license allow-list needs the repo's real dependency tree (Tauri pulls many crates); the kit ships a conservative default and repos extend it in a repo-owned file if `deny.toml` cannot be both byte-owned and extended; the plan resolves which.
- CI time for a Tauri workspace: first run builds the whole dependency tree (minutes); later runs use the cache.

## Out of scope

Coverage, MSRV checks, mutation testing, semver checks (libraries only), Windows/macOS CI in the kit, docstring gates for the python and TS profiles (a natural follow-up once the rust one has run for a while).
