// quality-kit stamped file — do not edit in the repo; change the kit instead.
export const agentLegibilityOptions: Record<
  string,
  number | Record<string, number | boolean>
> = {
  complexity: 10,
  "max-depth": 3,
  "max-lines": { max: 500, skipBlankLines: true, skipComments: true },
  "max-lines-per-function": {
    max: 80,
    skipBlankLines: true,
    skipComments: true,
  },
};

export const withAgentLegibilityOptions = (
  rule: string,
  level: "error" | "warn" | "off"
) => {
  const options = agentLegibilityOptions[rule];
  return options === undefined || level === "off" ? level : [level, options];
};

export const agentLegibilityRules = Object.fromEntries(
  Object.keys(agentLegibilityOptions).map((rule) => [
    rule,
    withAgentLegibilityOptions(rule, "error"),
  ])
);
