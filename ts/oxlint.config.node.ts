// quality-kit stamped file — do not edit in the repo; change the kit instead.
import { defineConfig } from "oxlint";
import core from "ultracite/oxlint/core";

export default defineConfig({
  extends: [core],
  ignorePatterns: core.ignorePatterns,
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
  },
});
