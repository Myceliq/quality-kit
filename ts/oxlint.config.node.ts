import { readFileSync } from "node:fs";

// quality-kit stamped file — do not edit in the repo; change the kit instead.
import { defineConfig } from "oxlint";
import core from "ultracite/oxlint/core";

// Repo-specific overrides, declared once in .quality-kit.json and self-applied
// here so this file stays byte-identical across the fleet (the drift gate
// compares it byte-for-byte). Resolved against import.meta.url — i.e. relative
// to this config, not the cwd — so oxlint run from a subdirectory still finds it.
interface QualityKit {
  ruleOverrides?: {
    burnDown?: Record<string, number>;
    permanent?: Record<string, { level: "off" | "warn"; why: string }>;
  };
  ignoreOverrides?: string[];
}
// In a stamped repo .quality-kit.json is a guaranteed sibling (the drift gate
// hard-fails without it); when it is absent (unstamped or partial-stamp context)
// fall back to no overrides so fleet rules still apply — stricter, never weaker.
// A malformed file stays loud: only ENOENT is caught, anything else re-throws.
let qk: QualityKit = {};
try {
  qk = JSON.parse(
    readFileSync(new URL(".quality-kit.json", import.meta.url), "utf-8")
  ) as QualityKit;
} catch (error) {
  if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
    throw error;
  }
}
// burn-down stays at `warn`: switching it off would hide the very violations
// the drift ratchet has to count.
const burnDown = Object.fromEntries(
  Object.keys(qk.ruleOverrides?.burnDown ?? {}).map((r) => [r, "warn"])
);
const permanent = Object.fromEntries(
  Object.entries(qk.ruleOverrides?.permanent ?? {}).map(([r, v]) => [
    r,
    v.level,
  ])
);

export default defineConfig({
  extends: [core],
  ignorePatterns: [
    ...[core].flatMap((c) => c.ignorePatterns ?? []),
    // The stamped CI workflow checks this kit out INTO the repo, at
    // .quality-kit-src/, so the drift gate can run before install. Without
    // this the repo lints the kit's own source as if it were repo code: the
    // three oxlint configs each carry two type assertions, so every CI
    // burn-down count came out six higher than any local run could
    // reproduce, and a locally seeded baseline could never match CI.
    ".quality-kit-src/**",
    ...(qk.ignoreOverrides ?? []),
  ],
  rules: {
    // Keep the rule for `return undefined` / `x = undefined`, but stop it
    // stripping type-REQUIRED argument undefineds — e.g. Vitest 4's
    // `mockResolvedValue(undefined)`, where removing the arg is a type error.
    "unicorn/no-useless-undefined": ["error", { checkArguments: false }],
    ...burnDown,
    ...permanent,
  },
});
