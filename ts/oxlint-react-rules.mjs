// quality-kit stamped file — do not edit in the repo; change the kit instead.
// What: the oxlint JS plugin behind the `custom` rows of ts/react-rules/coverage.json,
//       one rule per Vercel React rule a machine can decide, named after that
//       rule's id. Where: stamped beside oxlint.config.ts in nextjs-profile repos.
// Why:  no oxlint rule covers these, and each one here is proved on its own
//       vendored incorrect and correct examples by ts/react-rules.test.sh.
//       oxlint prints a plugin rule as `quality-kit(<id>)`, so every message
//       ends with the `quality-kit/<id>` name the config and coverage.json use.

const PLUGIN = "quality-kit";
const SCROLL_BLOCKING_EVENTS = new Set([
  "mousewheel",
  "touchmove",
  "touchstart",
  "wheel",
]);
// addEventListener(type, listener, options): the options are the third argument.
const OPTIONS_INDEX = 2;
const WORD = /[$A-Z_a-z][\w$]*/gu;

const report = (context, node, id, text) => {
  context.report({ message: `${text} (${PLUGIN}/${id})`, node });
};

// The name `f` of a call to `f(...)` or `React.f(...)`; "" for any other callee.
// An unqualified name counts as React's unless the file binds it to an import from
// another module or declares it locally (the vendored examples import nothing).
// ponytail: top-level bindings only; use context.sourceCode.getScope for shadowing.
const isForeign = (context, name) =>
  context.sourceCode.ast.body.some((statement) => {
    let node = statement;
    if (node.type === "ExportNamedDeclaration" && node.declaration) {
      node = node.declaration;
    }
    if (node.type === "ImportDeclaration") {
      return (
        node.source.value !== "react" &&
        node.specifiers.some((s) => s.local.name === name)
      );
    }
    if (node.type === "FunctionDeclaration") {
      return node.id?.name === name;
    }
    return (
      node.type === "VariableDeclaration" &&
      node.declarations.some(
        (d) => d.id.type === "Identifier" && d.id.name === name
      )
    );
  });

const reactCallee = (context, call) => {
  const { callee } = call;
  if (callee.type === "Identifier") {
    return isForeign(context, callee.name) ? "" : callee.name;
  }
  if (
    callee.type === "MemberExpression" &&
    !callee.computed &&
    callee.object.type === "Identifier" &&
    callee.object.name === "React"
  ) {
    return callee.property.name;
  }
  return "";
};

// The method name `m` of a call to `x.m(...)`; "" for any other callee.
const methodName = (call) => {
  const { callee } = call;
  if (callee.type === "MemberExpression" && !callee.computed) {
    return callee.property.name;
  }
  return "";
};

const words = (context, node) =>
  new Set(context.sourceCode.getText(node).match(WORD));

const isAwaitedDeclaration = (statement) =>
  statement.type === "VariableDeclaration" &&
  statement.declarations.length === 1 &&
  statement.declarations[0].init?.type === "AwaitExpression";

// Consecutive `const x = await ...` declarations in one statement list, where a
// later await reads no name an earlier one in the run declared. Read as text, so
// a name that only appears in a string still counts as read: a missed report,
// never a false one. Bare `await save();` statements are left alone — their
// order is usually the point.
// ponytail: names, not scopes — a shadowing callback parameter reads as a
// dependency; resolve references through context.sourceCode.getScope if it matters.
const checkAwaits = (context, statements) => {
  let declared = new Set();
  for (const statement of statements) {
    if (isAwaitedDeclaration(statement)) {
      const [declarator] = statement.declarations;
      const read = words(context, declarator.init);
      if (declared.size > 0 && ![...declared].some((n) => read.has(n))) {
        report(
          context,
          statement,
          "async-parallel",
          "This await reads nothing the await before it produced, so the two run one after the other; start them together with Promise.all()"
        );
      }
      declared = new Set([...declared, ...words(context, declarator.id)]);
    } else {
      declared = new Set();
    }
  }
};

const rules = {
  "async-parallel": {
    create(context) {
      return {
        BlockStatement(node) {
          checkAwaits(context, node.body);
        },
        Program(node) {
          checkAwaits(context, node.body);
        },
      };
    },
  },
  "client-passive-event-listeners": {
    create(context) {
      return {
        CallExpression(node) {
          const [type] = node.arguments;
          if (
            methodName(node) === "addEventListener" &&
            node.arguments.length <= OPTIONS_INDEX &&
            type?.type === "Literal" &&
            SCROLL_BLOCKING_EVENTS.has(type.value)
          ) {
            report(
              context,
              node,
              "client-passive-event-listeners",
              "A touch or wheel listener without options makes scrolling wait for it; pass { passive: true }, or { passive: false } when it calls preventDefault()"
            );
          }
        },
      };
    },
  },
  "js-flatmap-filter": {
    create(context) {
      return {
        CallExpression(node) {
          const [predicate] = node.arguments;
          const { object } = node.callee;
          if (
            methodName(node) === "filter" &&
            node.arguments.length === 1 &&
            predicate.type === "Identifier" &&
            predicate.name === "Boolean" &&
            object.type === "CallExpression" &&
            methodName(object) === "map"
          ) {
            report(
              context,
              node,
              "js-flatmap-filter",
              ".map(...).filter(Boolean) builds an intermediate array and iterates twice; use .flatMap() and return [] for the dropped items"
            );
          }
        },
      };
    },
  },
  "react19-no-forwardref": {
    create(context) {
      return {
        CallExpression(node) {
          const name = reactCallee(context, node);
          if (name === "forwardRef") {
            report(
              context,
              node,
              "react19-no-forwardref",
              "React 19 passes ref as a regular prop; take ref from props instead of wrapping the component in forwardRef()"
            );
          } else if (name === "useContext") {
            report(
              context,
              node,
              "react19-no-forwardref",
              "React 19's use() replaces useContext()"
            );
          }
        },
      };
    },
  },
  "rerender-lazy-state-init": {
    create(context) {
      return {
        CallExpression(node) {
          const [initial] = node.arguments;
          if (
            reactCallee(context, node) === "useState" &&
            (initial?.type === "CallExpression" ||
              initial?.type === "NewExpression")
          ) {
            report(
              context,
              node,
              "rerender-lazy-state-init",
              "useState runs this initial-value call on every render; pass a function instead, useState(() => ...)"
            );
          }
        },
      };
    },
  },
};

export default { meta: { name: PLUGIN }, rules };
