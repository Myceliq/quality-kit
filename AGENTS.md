# Quality-kit contributor context

## Third-party reference sources

Before changing Oxlint or Ruff integration, grep their checked-out source; do
not guess rule ids or option shapes:

- `reference/repos/github.com/oxc-project/oxc`
- `reference/repos/github.com/astral-sh/ruff`

Run the focused suites with the real tools:

```sh
OXLINT_BIN="$PWD/ci/oxlint-toolchain/node_modules/.bin/oxlint" bash ts/oxlint-overrides.test.sh
bash bin/render-ruff.test.sh
bash bin/baseline-rules.test.sh
bash bin/stamp.test.sh
bash bin/check-drift.test.sh
```

The complete suite and toolchain setup are authoritative in
`.github/workflows/tests.yml`.
