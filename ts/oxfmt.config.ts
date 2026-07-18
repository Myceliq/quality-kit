// quality-kit stamped file — do not edit in the repo; change the kit instead.
import { defineConfig } from "oxfmt";
import ultracite from "ultracite/oxfmt";

export default defineConfig({
  ...ultracite,
  // A code-quality kit formats CODE, not docs/data. oxfmt (prettier-based)
  // otherwise reformats Markdown/JSON/YAML too: that is churn with no
  // code-quality value AND actively corrupts prose-markdown used as data
  // (e.g. a wiki corpus whose scrubbed output is format-sensitive — `*x*` →
  // `_x_` changes what downstream consumers read). Restrict formatting to the
  // JS/TS family; `extends` does not merge ignorePatterns, so merge explicitly.
  ignorePatterns: [
    ...(ultracite.ignorePatterns ?? []),
    "**/*.md",
    "**/*.mdx",
    "**/*.json",
    "**/*.jsonc",
    "**/*.yaml",
    "**/*.yml",
  ],
});
