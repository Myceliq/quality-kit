// quality-kit stamped file — do not edit in the repo; change the kit instead.
import { defineConfig } from "oxlint";
import core from "ultracite/oxlint/core";

export default defineConfig({
  extends: [core],
  ignorePatterns: core.ignorePatterns,
});
