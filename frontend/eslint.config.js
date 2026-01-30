/**
 * ESLint configuration for REAmo frontend
 *
 * Enforces patterns from FRONTEND_DEVELOPMENT.md to prevent common bugs and
 * maintain design system consistency. Rules are organized by the section they
 * correspond to in the development guide.
 *
 * @see FRONTEND_DEVELOPMENT.md
 * @see docs/architecture/ESLINT_GOVERNANCE.md
 */

import js from '@eslint/js';
import globals from 'globals';
import reactHooks from 'eslint-plugin-react-hooks';
import reactRefresh from 'eslint-plugin-react-refresh';
import tseslint from 'typescript-eslint';
import { reamoRules } from './eslint-rules/index.js';

export default tseslint.config(
  // Global ignores
  { ignores: ['dist/', 'node_modules/', '.eslintcache', 'coverage/', 'playwright-report/'] },

  // Base TypeScript/React configuration
  {
    files: ['**/*.{ts,tsx}'],
    extends: [js.configs.recommended, ...tseslint.configs.recommended],
    languageOptions: {
      ecmaVersion: 2020,
      globals: globals.browser,
    },
    plugins: {
      'react-hooks': reactHooks,
      'react-refresh': reactRefresh,
      reamo: reamoRules,
    },
    rules: {
      // React hooks rules
      ...reactHooks.configs.recommended.rules,
      'react-refresh/only-export-components': ['warn', { allowConstantExport: true }],

      // =========================================================================
      // REAMO CUSTOM RULES
      // @see FRONTEND_DEVELOPMENT.md §4 Memory Safety
      // =========================================================================

      // Warn when useEffect has timers/listeners without cleanup
      'reamo/require-effect-cleanup': 'warn',

      // Warn when useState is used for timer IDs (should use useRef)
      'reamo/no-state-for-timer-ids': 'warn',

      // =========================================================================
      // NO-RESTRICTED-SYNTAX RULES
      // Quick wins using AST selectors for common anti-patterns
      // =========================================================================

      'no-restricted-syntax': [
        'warn',

        // ---------------------------------------------------------------------
        // §5 React 19 Patterns - useRef requires initial value
        // ---------------------------------------------------------------------
        {
          selector: "CallExpression[callee.name='useRef'][arguments.length=0]",
          message:
            'useRef<T>() requires initial value in React 19. Use useRef<T | null>(null). See FRONTEND_DEVELOPMENT.md §5.',
        },
        {
          selector:
            "CallExpression[callee.object.name='React'][callee.property.name='useRef'][arguments.length=0]",
          message:
            'React.useRef<T>() requires initial value in React 19. Use useRef<T | null>(null). See FRONTEND_DEVELOPMENT.md §5.',
        },

        // ---------------------------------------------------------------------
        // §6 Zustand 5 Patterns - Selector stability
        // ---------------------------------------------------------------------
        // Array selector without useShallow (implicit return)
        {
          selector:
            "CallExpression[callee.name='useStore'] ArrowFunctionExpression > ArrayExpression.body",
          message:
            'Array selector creates new reference each render causing infinite loops. Use useShallow() or split into atomic selectors. See FRONTEND_DEVELOPMENT.md §6.',
        },
        // Array selector without useShallow (explicit return)
        {
          selector:
            "CallExpression[callee.name='useStore'] ArrowFunctionExpression ReturnStatement > ArrayExpression",
          message:
            'Array selector creates new reference each render. Use useShallow() or atomic selectors. See FRONTEND_DEVELOPMENT.md §6.',
        },
        // Object selector without useShallow
        {
          selector:
            "CallExpression[callee.name='useStore'] ArrowFunctionExpression > ObjectExpression.body",
          message:
            'Object selector creates new reference each render. Use useShallow() or atomic selectors. See FRONTEND_DEVELOPMENT.md §6.',
        },
        // Also catch useReaperStore
        {
          selector:
            "CallExpression[callee.name='useReaperStore'] ArrowFunctionExpression > ArrayExpression.body",
          message:
            'Array selector creates new reference each render. Use useShallow() or atomic selectors. See FRONTEND_DEVELOPMENT.md §6.',
        },
        {
          selector:
            "CallExpression[callee.name='useReaperStore'] ArrowFunctionExpression > ObjectExpression.body",
          message:
            'Object selector creates new reference each render. Use useShallow() or atomic selectors. See FRONTEND_DEVELOPMENT.md §6.',
        },

        // ---------------------------------------------------------------------
        // §6 Zustand 5 Patterns - Fallback object stability
        // ---------------------------------------------------------------------
        // Inline ?? {} creates new object each render
        {
          selector: "LogicalExpression[operator='??'] > ObjectExpression.right",
          message:
            'Inline ?? {} creates new object each render. Use stable reference from stableRefs.ts (e.g., EMPTY_TRACKS). See FRONTEND_DEVELOPMENT.md §6.',
        },
        // Inline ?? [] creates new array each render
        {
          selector: "LogicalExpression[operator='??'] > ArrayExpression.right",
          message:
            'Inline ?? [] creates new array each render. Use stable reference from stableRefs.ts (e.g., EMPTY_ARRAY). See FRONTEND_DEVELOPMENT.md §6.',
        },
        // Also catch || fallbacks
        {
          selector: "LogicalExpression[operator='||'] > ObjectExpression.right",
          message:
            'Inline || {} creates new object each render. Use stable reference from stableRefs.ts. See FRONTEND_DEVELOPMENT.md §6.',
        },
        {
          selector: "LogicalExpression[operator='||'] > ArrayExpression.right",
          message:
            'Inline || [] creates new array each render. Use stable reference from stableRefs.ts. See FRONTEND_DEVELOPMENT.md §6.',
        },

        // ---------------------------------------------------------------------
        // §7 WebSocket & Connection - Use context, not hook directly
        // ---------------------------------------------------------------------
        {
          selector: "CallExpression[callee.name='useReaperConnection']",
          message:
            'Use useReaper() from ReaperProvider context instead. useReaperConnection() creates duplicate WebSocket connections. See FRONTEND_DEVELOPMENT.md §7.',
        },

        // ---------------------------------------------------------------------
        // §11 PWA & iOS Safari - Use dvh instead of vh
        // ---------------------------------------------------------------------
        // Catch className containing "h-screen" without dvh
        // Note: This is a heuristic - we can't perfectly detect all vh usage
        {
          selector:
            "JSXAttribute[name.name='className'] Literal[value=/\\bh-screen\\b(?!-safe)/]",
          message:
            'Use h-screen-safe or 100dvh instead of h-screen for iOS Safari URL bar. See FRONTEND_DEVELOPMENT.md §11.',
        },
      ],

      // =========================================================================
      // NO-RESTRICTED-IMPORTS
      // @see FRONTEND_DEVELOPMENT.md §14 Bundle Size
      // =========================================================================

      'no-restricted-imports': [
        'error',
        {
          paths: [
            {
              name: 'lucide-react',
              importNames: ['icons'],
              message:
                "Don't import all icons. Use individual imports (e.g., import { Play } from 'lucide-react') or commonIcons.ts. See FRONTEND_DEVELOPMENT.md §14.",
            },
          ],
          patterns: [
            {
              group: ['lucide-react/dist/esm/icons/*'],
              message: "Use direct imports from 'lucide-react' instead.",
            },
          ],
        },
      ],

      // =========================================================================
      // TYPESCRIPT RULES
      // =========================================================================

      // Allow unused vars starting with underscore
      '@typescript-eslint/no-unused-vars': [
        'warn',
        {
          argsIgnorePattern: '^_',
          varsIgnorePattern: '^_',
          caughtErrorsIgnorePattern: '^_',
        },
      ],

      // Disable rules that conflict with our patterns
      '@typescript-eslint/no-empty-object-type': 'off',
    },
  },

  // =========================================================================
  // BUTTON PRIMITIVE ENFORCEMENT
  // Separate config so it can be disabled per-file
  // @see FRONTEND_DEVELOPMENT.md §1a Button System
  // =========================================================================
  {
    files: ['**/*.tsx'],
    rules: {
      // Warn on raw <button> elements - encourage design system usage
      // Disabled by default, enable when ready
      'reamo/prefer-button-primitive': 'off',
    },
  },

  // =========================================================================
  // FILE-SPECIFIC OVERRIDES
  // =========================================================================

  // Button primitive components can use raw <button>
  {
    files: [
      'src/components/Transport/CircularTransportButton.tsx',
      'src/components/Modal/ModalFooter.tsx',
      'src/components/Track/*.tsx',
      'src/components/Toolbar/ToolbarButton.tsx',
    ],
    rules: {
      'reamo/prefer-button-primitive': 'off',
    },
  },

  // Transport components with custom pointer handlers - intentional raw buttons
  {
    files: ['src/components/Transport/TransportBar.tsx', 'src/components/PersistentTransport.tsx'],
    rules: {
      'reamo/prefer-button-primitive': 'off',
    },
  },

  // QuickActionsPanel - large touch-friendly actions with specific layout
  {
    files: ['src/components/QuickActionsPanel.tsx'],
    rules: {
      'reamo/prefer-button-primitive': 'off',
    },
  },

  // ReaperProvider is the ONE place that should call useReaperConnection
  {
    files: ['src/components/ReaperProvider.tsx'],
    rules: {
      'no-restricted-syntax': 'off',
    },
  },

  // Test files - relaxed rules
  {
    files: ['**/*.test.ts', '**/*.test.tsx', '**/*.spec.ts', '**/*.spec.tsx'],
    rules: {
      '@typescript-eslint/no-explicit-any': 'off',
      'reamo/require-effect-cleanup': 'off',
      'reamo/no-state-for-timer-ids': 'off',
      'no-restricted-syntax': 'off',
    },
  },

  // E2E test files
  {
    files: ['e2e/**/*.ts'],
    rules: {
      '@typescript-eslint/no-explicit-any': 'off',
      'no-restricted-syntax': 'off',
    },
  },

  // Scripts - different environment
  {
    files: ['scripts/**/*.ts'],
    languageOptions: {
      globals: {
        ...globals.node,
      },
    },
    rules: {
      'no-restricted-syntax': 'off',
    },
  },

  // Zustand store slices - ?? [] in actions is safe (run once on dispatch, not every render)
  {
    files: ['src/store/slices/*.ts'],
    rules: {
      'no-restricted-syntax': 'off',
    },
  },

  // Transport sync library - plain TypeScript classes, not React components
  // ?? {} in non-React code doesn't trigger re-renders
  {
    files: ['src/lib/transport-sync/*.ts'],
    rules: {
      'no-restricted-syntax': 'off',
    },
  }
);
