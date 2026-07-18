// quality-kit stamped file — do not edit in the repo; change the kit instead.
import { defineConfig } from "oxlint";
import core from "ultracite/oxlint/core";
import react from "ultracite/oxlint/react";

export default defineConfig({
  extends: [core, react],
  // extends does not merge ignorePatterns automatically (verified against
  // oxlint 1.74.0) — merge explicitly so a future preset's own patterns
  // aren't silently dropped.
  ignorePatterns: [core, react].flatMap((c) => c.ignorePatterns ?? []),
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
  },
});
