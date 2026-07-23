// quality-kit stamped file — do not edit in the repo; change the kit instead.
import { defineConfig } from "oxlint";
import core from "ultracite/oxlint/core";
import react from "ultracite/oxlint/react";
import { readFileSync } from "node:fs";

// Repo-specific overrides, declared once in .quality-kit.json and self-applied
// here so this file stays byte-identical across the fleet (the drift gate
// compares it byte-for-byte). Resolved against import.meta.url — i.e. relative
// to this config, not the cwd — so oxlint run from a subdirectory still finds it.
type QualityKit = {
  ruleOverrides?: {
    burnDown?: Record<string, number>;
    permanent?: Record<string, { level: "off" | "warn"; why: string }>;
  };
  ignoreOverrides?: string[];
};
// In a stamped repo .quality-kit.json is a guaranteed sibling (the drift gate
// hard-fails without it); when it is absent (unstamped or partial-stamp context)
// fall back to no overrides so fleet rules still apply — stricter, never weaker.
// A malformed file stays loud: only ENOENT is caught, anything else re-throws.
let qk: QualityKit = {};
try {
  qk = JSON.parse(
    readFileSync(new URL(".quality-kit.json", import.meta.url), "utf8"),
  ) as QualityKit;
} catch (e) {
  if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e;
}
// burn-down stays at `warn`: switching it off would hide the very violations
// the drift ratchet has to count.
const burnDown = Object.fromEntries(
  Object.keys(qk.ruleOverrides?.burnDown ?? {}).map((r) => [r, "warn"]),
);
const permanent = Object.fromEntries(
  Object.entries(qk.ruleOverrides?.permanent ?? {}).map(([r, v]) => [r, v.level]),
);

export default defineConfig({
  extends: [core, react],
  // extends does not merge ignorePatterns automatically (verified against
  // oxlint 1.74.0) — merge explicitly so a future preset's own patterns
  // aren't silently dropped.
  ignorePatterns: [
    ...[core, react].flatMap((c) => c.ignorePatterns ?? []),
    ...(qk.ignoreOverrides ?? []),
  ],
  // Fleet policy (Wave-1 pilot, operator decision): off in the standard.
  // no-inline-comments contradicts the documented inline-comment doctrine;
  // the any / type-assertion / non-null-assertion family is an accepted
  // escape hatch whose removal churns code without improving it.
  rules: {
    "no-inline-comments": "off",
    "typescript/no-explicit-any": "off",
    "typescript/no-non-null-assertion": "off",
    "typescript/no-unsafe-argument": "off",
    "typescript/no-unsafe-assignment": "off",
    "typescript/no-unsafe-call": "off",
    "typescript/no-unsafe-member-access": "off",
    "typescript/no-unsafe-return": "off",
    "typescript/no-unsafe-type-assertion": "off",
    // Keep the rule for `return undefined` / `x = undefined`, but stop it
    // stripping type-REQUIRED argument undefineds — e.g. Vitest 4's
    // `mockResolvedValue(undefined)`, where removing the arg is a type error.
    "unicorn/no-useless-undefined": ["error", { checkArguments: false }],
    ...burnDown,
    ...permanent,
  },
});
