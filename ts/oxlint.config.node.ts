// quality-kit stamped file — do not edit in the repo; change the kit instead.
import { defineConfig } from "oxlint";
import core from "ultracite/oxlint/core";

export default defineConfig({
  extends: [core],
  ignorePatterns: core.ignorePatterns,
  rules: {
    // Keep the rule for `return undefined` / `x = undefined`, but stop it
    // stripping type-REQUIRED argument undefineds — e.g. Vitest 4's
    // `mockResolvedValue(undefined)`, where removing the arg is a type error.
    "unicorn/no-useless-undefined": ["error", { checkArguments: false }],
  },
});
