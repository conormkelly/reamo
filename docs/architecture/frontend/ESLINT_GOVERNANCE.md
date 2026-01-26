# ESLint governance for React 19 + Zustand 5 + TypeScript projects

**Most of your bug-prevention patterns require custom rules, but several can be caught using `no-restricted-syntax` with AST selectors.** The existing ESLint plugin ecosystem covers React hooks rules and TypeScript typing but has significant gaps around Zustand selectors, cleanup patterns, and reference stability—the exact anti-patterns you've identified. Here's a complete implementation strategy prioritized by bug-prevention ROI.

## Priority 1 patterns: what's covered vs what needs custom rules

The good news: **4 of your 6 priority patterns can be detected with `no-restricted-syntax`** without writing custom rule implementations. The remaining patterns require custom rules due to cross-node analysis requirements.

| Anti-pattern | Detection method | Complexity |
|--------------|------------------|------------|
| `useRef<T>()` missing null | `no-restricted-syntax` ✅ | Low |
| Zustand selector array/object returns | `no-restricted-syntax` ✅ | Low |
| `?? {}` inline objects | `no-restricted-syntax` ✅ | Low |
| Map mutation on state | Custom rule (type-aware) | High |
| Timer cleanup in useEffect | Custom rule (cross-node) | High |
| useState for timer IDs | Custom rule (heuristic) | Medium |

**eslint-plugin-react-hooks** (v6.1.0+) provides `exhaustive-deps` and `rules-of-hooks` but **does not detect missing cleanup patterns**. The newer React Compiler rules add immutability and ref validation but still don't cover your timer/cleanup scenarios. **@typescript-eslint/eslint-plugin** (v8.53.0) has no useRef initialization rules. **eslint-plugin-zustand** exists but only provides `no-destructure`—no useShallow detection.

## Working `no-restricted-syntax` configurations

These selectors handle the patterns detectable through pure AST analysis:

```javascript
// eslint.config.js - no-restricted-syntax rules
{
  rules: {
    "no-restricted-syntax": [
      "error",
      // 1. useRef() without null argument
      {
        selector: "CallExpression[callee.name='useRef'][arguments.length=0]",
        message: "useRef<T>() must include initial value: useRef<T | null>(null)"
      },
      // Handle React.useRef() pattern
      {
        selector: "CallExpression[callee.object.name='React'][callee.property.name='useRef'][arguments.length=0]",
        message: "React.useRef<T>() must include initial value: useRef<T | null>(null)"
      },
      
      // 2. Zustand selector returning array (implicit return)
      {
        selector: "CallExpression[callee.name='useStore'] ArrowFunctionExpression > ArrayExpression.body",
        message: "Array selector creates new reference each render. Use useShallow() or split into atomic selectors."
      },
      // Zustand selector returning array (explicit return)
      {
        selector: "CallExpression[callee.name='useStore'] ArrowFunctionExpression ReturnStatement > ArrayExpression",
        message: "Array selector creates new reference each render. Use useShallow() or split into atomic selectors."
      },
      // Zustand selector returning object
      {
        selector: "CallExpression[callee.name='useStore'] ArrowFunctionExpression > ObjectExpression.body",
        message: "Object selector creates new reference each render. Use useShallow() or split into atomic selectors."
      },
      
      // 3. Inline object/array in nullish coalescing
      {
        selector: "LogicalExpression[operator='??'] > ObjectExpression.right",
        message: "Inline ?? {} creates new object each render. Extract to module constant: const EMPTY = {};"
      },
      {
        selector: "LogicalExpression[operator='??'] > ArrayExpression.right",
        message: "Inline ?? [] creates new array each render. Extract to module constant: const EMPTY = [];"
      },
      // Also catch || fallbacks
      {
        selector: "LogicalExpression[operator='||'] > ObjectExpression.right",
        message: "Inline || {} creates new object each render. Extract to module constant."
      },
      {
        selector: "LogicalExpression[operator='||'] > ArrayExpression.right",
        message: "Inline || [] creates new array each render. Extract to module constant."
      },
      
      // 4. Timer warnings (can only warn, not verify cleanup exists)
      {
        selector: "CallExpression[callee.name='useEffect'] CallExpression[callee.name='setTimeout']",
        message: "setTimeout in useEffect requires cleanup. Return clearTimeout in cleanup function."
      },
      {
        selector: "CallExpression[callee.name='useEffect'] CallExpression[callee.name='setInterval']",
        message: "setInterval in useEffect requires cleanup. Return clearInterval in cleanup function."
      },
    ],
  },
}
```

**Limitations**: The timer selectors only *warn* about patterns that need cleanup—they cannot verify cleanup actually exists. Cross-node analysis (matching setTimeout with clearTimeout) requires a custom rule.

## Custom plugin structure for ESLint 9 flat config

ESLint 9's flat config enables inline plugin definition without the old boilerplate:

```javascript
// eslint.config.js
import js from "@eslint/js";
import tseslint from "typescript-eslint";

// Define custom rules inline
const projectRules = {
  meta: {
    name: "eslint-plugin-project",
    version: "1.0.0",
  },
  rules: {
    "require-useeffect-cleanup": {
      meta: {
        type: "problem",
        docs: { description: "Require cleanup for timers/listeners in useEffect" },
        messages: {
          missingCleanup: "useEffect with {{pattern}} must return a cleanup function",
          missingTimerNull: "After clearTimeout/clearInterval, set ref.current = null",
        },
        schema: [],
      },
      create(context) {
        const patternsNeedingCleanup = {
          setTimeout: "clearTimeout",
          setInterval: "clearInterval",
          addEventListener: "removeEventListener",
          requestAnimationFrame: "cancelAnimationFrame",
        };
        
        return {
          "CallExpression[callee.name='useEffect']"(node) {
            const callback = node.arguments[0];
            if (!callback || !["ArrowFunctionExpression", "FunctionExpression"].includes(callback.type)) return;
            
            const sourceCode = context.sourceCode;
            const callbackText = sourceCode.getText(callback);
            
            for (const [setup, cleanup] of Object.entries(patternsNeedingCleanup)) {
              if (callbackText.includes(setup) && !callbackText.includes(cleanup)) {
                // Check for return statement
                const hasReturn = callback.body.type === "BlockStatement" &&
                  callback.body.body.some(stmt => stmt.type === "ReturnStatement");
                
                if (!hasReturn) {
                  context.report({
                    node: callback,
                    messageId: "missingCleanup",
                    data: { pattern: setup },
                  });
                }
              }
            }
          },
        };
      },
    },
    
    "no-usestate-for-timer-ids": {
      meta: {
        type: "suggestion",
        docs: { description: "Prefer useRef over useState for timer IDs" },
        messages: {
          useRefInstead: "Timer IDs should use useRef, not useState, to avoid re-renders and stale closures",
        },
        schema: [],
      },
      create(context) {
        const timerSetters = new Set();
        
        return {
          // Track useState declarations that look like timer state
          "VariableDeclarator[init.callee.name='useState']"(node) {
            const id = node.id;
            if (id.type !== "ArrayPattern" || id.elements.length < 2) return;
            
            const stateName = id.elements[0]?.name?.toLowerCase() || "";
            const setterName = id.elements[1]?.name || "";
            
            // Heuristic: names containing timer, timeout, interval, animation
            if (/timer|timeout|interval|animation|raf/i.test(stateName)) {
              timerSetters.add(setterName);
              context.report({
                node,
                messageId: "useRefInstead",
              });
            }
          },
          
          // Also flag when useState setter is called with setTimeout/setInterval return
          "CallExpression"(node) {
            const calleeName = node.callee.name;
            if (!timerSetters.has(calleeName)) return;
            
            const arg = node.arguments[0];
            if (arg?.type === "CallExpression" && 
                ["setTimeout", "setInterval"].includes(arg.callee.name)) {
              context.report({
                node,
                messageId: "useRefInstead",
              });
            }
          },
        };
      },
    },
  },
};

export default [
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    plugins: {
      project: projectRules,
    },
    rules: {
      "project/require-useeffect-cleanup": "error",
      "project/no-usestate-for-timer-ids": "warn",
    },
  },
];
```

## Type-aware rule for Map mutation detection

Map mutation detection **requires TypeScript type information** because AST alone cannot distinguish `Map.set()` from `URLSearchParams.set()`:

```typescript
// rules/no-map-mutation.ts
import { ESLintUtils } from "@typescript-eslint/utils";

export const noMapMutation = ESLintUtils.RuleCreator.withoutDocs({
  meta: {
    type: "problem",
    messages: {
      noMutation: "Do not mutate Map with {{method}}(). Create new Map: new Map(state.map).{{method}}(k, v)",
    },
    schema: [],
  },
  defaultOptions: [],
  
  create(context) {
    const services = ESLintUtils.getParserServices(context);
    const mutatingMethods = ["set", "delete", "clear"];
    
    return {
      CallExpression(node) {
        if (node.callee.type !== "MemberExpression") return;
        
        const methodName = node.callee.property.type === "Identifier" 
          ? node.callee.property.name 
          : null;
          
        if (!methodName || !mutatingMethods.includes(methodName)) return;
        
        const objectType = services.getTypeAtLocation(node.callee.object);
        const typeChecker = services.program.getTypeChecker();
        const typeName = typeChecker.typeToString(objectType);
        
        if (typeName.startsWith("Map<") || typeName === "Map") {
          context.report({
            node,
            messageId: "noMutation",
            data: { method: methodName },
          });
        }
      },
    };
  },
});
```

**Performance note**: Type-aware rules add **10-30 seconds** to lint time on large projects. Use `parserOptions: { projectService: true }` (v8+) for better performance than the older `project` option.

## Complete eslint.config.js structure

```javascript
// eslint.config.js
import js from "@eslint/js";
import tseslint from "typescript-eslint";
import react from "eslint-plugin-react";
import reactHooks from "eslint-plugin-react-hooks";
import reactRefresh from "eslint-plugin-react-refresh";
import tailwindcss from "eslint-plugin-tailwindcss";
import eslintComments from "@eslint-community/eslint-plugin-eslint-comments/configs";

// Import your custom rules
import { projectRules } from "./eslint-rules/index.js";

export default tseslint.config(
  // Global ignores
  { ignores: ["dist/", "node_modules/", ".eslintcache", "coverage/"] },
  
  // Base configs
  js.configs.recommended,
  ...tseslint.configs.recommendedTypeChecked,
  eslintComments.recommended,
  
  // TypeScript parser settings
  {
    languageOptions: {
      parserOptions: {
        projectService: true,
        tsconfigRootDir: import.meta.dirname,
      },
    },
  },
  
  // React configuration
  {
    files: ["**/*.tsx", "**/*.jsx"],
    plugins: { react, "react-hooks": reactHooks, "react-refresh": reactRefresh },
    rules: {
      ...react.configs.flat.recommended.rules,
      ...reactHooks.configs.recommended.rules,
      "react-refresh/only-export-components": ["warn", { allowConstantExport: true }],
      "react/react-in-jsx-scope": "off",
      "react/jsx-no-constructed-context-values": "error",
    },
    settings: { react: { version: "detect" } },
  },
  
  // Tailwind CSS
  ...tailwindcss.configs["flat/recommended"],
  {
    rules: {
      "tailwindcss/no-arbitrary-value": "warn", // Encourage design tokens
    },
  },
  
  // Custom project rules
  {
    plugins: { project: projectRules },
    rules: {
      "project/require-useeffect-cleanup": "error",
      "project/no-usestate-for-timer-ids": "warn",
      "project/no-map-mutation": "error",
    },
  },
  
  // no-restricted-syntax for quick wins
  {
    rules: {
      "no-restricted-syntax": [
        "error",
        {
          selector: "CallExpression[callee.name='useRef'][arguments.length=0]",
          message: "useRef<T>() requires initial value. Use useRef<T | null>(null) for DOM refs.",
        },
        {
          selector: "CallExpression[callee.name='useStore'] ArrowFunctionExpression > ArrayExpression.body",
          message: "Wrap with useShallow() or split into atomic selectors to prevent rerenders.",
        },
        {
          selector: "LogicalExpression[operator='??'] > ObjectExpression.right",
          message: "Extract ?? {} to module constant: const EMPTY_OBJ = {};",
        },
        {
          selector: "LogicalExpression[operator='??'] > ArrayExpression.right",
          message: "Extract ?? [] to module constant: const EMPTY_ARR = [];",
        },
      ],
    },
  },
  
  // eslint-disable governance
  {
    rules: {
      "@eslint-community/eslint-comments/require-description": "error",
      "@eslint-community/eslint-comments/no-unlimited-disable": "error",
      "@eslint-community/eslint-comments/no-restricted-disable": [
        "error",
        "@typescript-eslint/no-explicit-any",
        "project/require-useeffect-cleanup",
      ],
    },
    linterOptions: {
      reportUnusedDisableDirectives: "error",
    },
  },
  
  // File-specific overrides
  {
    files: ["src/components/primitives/**/*.tsx"],
    rules: {
      // Primitives can use raw HTML elements
      "no-restricted-syntax": "off",
    },
  },
  
  // Test file relaxations
  {
    files: ["**/*.test.ts", "**/*.test.tsx", "**/*.spec.ts"],
    rules: {
      "@typescript-eslint/no-explicit-any": "off",
      "project/require-useeffect-cleanup": "off",
    },
  },
);
```

## Husky 9 + lint-staged setup

Husky 9 dramatically simplified the setup process:

```bash
# Installation
npm install --save-dev husky lint-staged

# Initialize Husky (creates .husky/ and adds prepare script)
npx husky init

# Configure pre-commit hook
echo "npx lint-staged" > .husky/pre-commit
```

**lint-staged.config.js** optimized for performance:

```javascript
// lint-staged.config.js
export default {
  "*.{ts,tsx}": [
    "eslint --cache --cache-location node_modules/.cache/.eslintcache --fix --max-warnings=0",
    "prettier --write",
  ],
  "*.{json,css,md}": ["prettier --write"],
};
```

**Performance strategy for <2 second target**: Skip type-aware rules in pre-commit. Create separate configs:

```javascript
// eslint.config.precommit.js - Fast rules only
import baseConfig from "./eslint.config.js";

export default [
  ...baseConfig,
  {
    rules: {
      // Disable slow type-aware rules for pre-commit
      "@typescript-eslint/no-floating-promises": "off",
      "@typescript-eslint/await-thenable": "off",
      "@typescript-eslint/no-unsafe-assignment": "off",
      "project/no-map-mutation": "off", // Type-aware custom rule
    },
  },
];
```

```javascript
// lint-staged.config.js
export default {
  "*.{ts,tsx}": [
    "eslint --config eslint.config.precommit.js --cache --fix --max-warnings=0",
    "prettier --write",
  ],
};
```

**Do NOT run `tsc --noEmit` in pre-commit**—it's too slow. Run full type checking and type-aware ESLint rules in CI only.

## Warning-to-error migration strategy

ESLint 9.39+ includes **native bulk suppressions**:

```bash
# Suppress all current violations when adding new rule
eslint --suppress-all --fix

# Creates eslint-suppressions.json tracking violations per file
# CI fails if violation count INCREASES in any file

# Clean up fixed violations periodically
eslint --prune-suppressions
```

For gradual migration without suppressions:

1. Add new rules as `"warn"`
2. Set `--max-warnings=<current-count>` in CI to prevent increase
3. Track count in CI logs over time
4. Promote to `"error"` once count reaches zero

**Install @eslint-community/eslint-plugin-eslint-comments** to enforce disable comment governance:

```javascript
{
  rules: {
    "@eslint-community/eslint-comments/require-description": "error",
    "@eslint-community/eslint-comments/no-unlimited-disable": "error",
  },
}
```

This forces developers to write `// eslint-disable-next-line rule-name -- justification here`.

## Implementation priority matrix

Based on bug-prevention ROI (impact × implementation effort):

| Priority | Pattern | Method | Effort | Impact |
|----------|---------|--------|--------|--------|
| **1** | Inline `?? {}` objects | no-restricted-syntax | 5 min | 🔥 High |
| **2** | `useRef()` without null | no-restricted-syntax | 5 min | 🔥 High |
| **3** | Zustand selector arrays | no-restricted-syntax | 10 min | 🔥 High |
| **4** | Timer cleanup warnings | no-restricted-syntax | 10 min | Medium |
| **5** | eslint-disable governance | Plugin config | 15 min | Medium |
| **6** | Timer cleanup validation | Custom rule | 2 hours | 🔥 High |
| **7** | useState for timer IDs | Custom rule | 1 hour | Medium |
| **8** | Map mutation detection | Type-aware rule | 3 hours | Medium |

**Start with items 1-5**—they provide immediate protection with minimal implementation time. Items 6-8 require custom rule development but catch subtle bugs the simpler approaches miss.

## Tailwind CSS semantic token enforcement

**eslint-plugin-tailwindcss** (v3.17.x stable, beta for v4) can partially enforce design tokens:

```javascript
{
  rules: {
    "tailwindcss/no-arbitrary-value": "warn", // Flags bg-[#ff0000]
    "tailwindcss/no-custom-classname": ["warn", {
      whitelist: ["text-primary", "bg-surface", "border-muted"], // Allow semantic classes
    }],
  },
}
```

For stricter enforcement of CSS variables over hardcoded colors, you'll need a custom rule or use **@poupe/eslint-plugin-tailwindcss** which has deeper Tailwind v4 integration and theme-aware validation.

The combination of `no-restricted-syntax` selectors for quick wins, custom rules for complex patterns, and proper governance through eslint-comments gives you comprehensive coverage of the React 19 + Zustand 5 anti-patterns you've identified—with a clear path from warnings to errors as your team fixes existing violations.
