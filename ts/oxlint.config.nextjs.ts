// quality-kit stamped file — do not edit in the repo; change the kit instead.
import { defineConfig } from "oxlint";
import core from "ultracite/oxlint/core";
import next from "ultracite/oxlint/next";
import react from "ultracite/oxlint/react";

export default defineConfig({
  extends: [core, react, next],
  // extends does not merge ignorePatterns automatically (verified against
  // oxlint 1.74.0) — merge explicitly so a future preset's own patterns
  // aren't silently dropped.
  ignorePatterns: [core, react, next].flatMap((c) => c.ignorePatterns ?? []),
  rules: {
    // Keep the rule for `return undefined` / `x = undefined`, but stop it
    // stripping type-REQUIRED argument undefineds — e.g. Vitest 4's
    // `mockResolvedValue(undefined)`, where removing the arg is a type error.
    "unicorn/no-useless-undefined": ["error", { checkArguments: false }],
  },
});
