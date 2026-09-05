import { readFileSync } from "node:fs";

// quality-kit stamped file — do not edit in the repo; change the kit instead.
import { defineConfig } from "oxlint";
import type { DummyRuleMap } from "oxlint";
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
// Rules this config sets itself, kept in a const so `configured` below sees
// them too — otherwise a severity override would strip THEIR options, which is
// the very bug `at()` exists to prevent.
const local = {
  // Keep the rule for `return undefined` / `x = undefined`, but stop it
  // stripping type-REQUIRED argument undefineds — e.g. Vitest 4's
  // `mockResolvedValue(undefined)`, where removing the arg is a type error.
  "unicorn/no-useless-undefined": ["error", { checkArguments: false }],
} satisfies DummyRuleMap;
// The severity overrides below re-declare a rule, and a re-declaration REPLACES
// the fleet's entry rather than merging into it. Written as a bare level it
// therefore also discarded the rule's OPTIONS, reverting it to its plugin
// defaults — which for an option-carrying rule is a materially different rule.
// `unicorn/text-encoding-identifier-case` is `["error", { withDash: true }]`
// fleet-wide (prefer `utf-8`); collapsed to `"warn"` it enforced the plugin
// default, the OPPOSITE spelling. Every stamped repo therefore counted the
// inverse violations into `burnDown` and enforced a rule nobody chose. Read the
// configured entry and swap only element 0, so the options survive.
const configured: Record<string, unknown> = {
  ...core.rules,
  ...local,
};
// A predicate, not `Array.isArray` inline: narrowing an `unknown` with the
// built-in yields `any[]`, and spreading that is an unsafe-assignment the fleet
// ruleset counts against every stamped repo. This config is linted BY the repos
// it is stamped into, so a violation here is charged to all of them.
const isTuple = (v: unknown): v is unknown[] => Array.isArray(v);
const at = (level: string, rule: string) => {
  const entry = configured[rule];
  return isTuple(entry) ? [level, ...entry.slice(1)] : level;
};
// burn-down stays at `warn`: switching it off would hide the very violations
// the drift ratchet has to count.
const burnDown = Object.fromEntries(
  Object.keys(qk.ruleOverrides?.burnDown ?? {}).map((r) => [r, at("warn", r)])
);
const permanent = Object.fromEntries(
  Object.entries(qk.ruleOverrides?.permanent ?? {}).map(([r, v]) => [
    r,
    at(v.level, r),
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
    ...local,
    ...burnDown,
    ...permanent,
  },
});
