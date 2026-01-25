/**
 * Custom ESLint rules for REAmo frontend
 *
 * These rules enforce patterns from FRONTEND_DEVELOPMENT.md that cannot be
 * detected with simple AST selectors in no-restricted-syntax.
 *
 * @see FRONTEND_DEVELOPMENT.md §4 Memory Safety, §5 React 19 Patterns, §6 Zustand 5 Patterns
 */

/** @type {import('eslint').ESLint.Plugin} */
export const reamoRules = {
  meta: {
    name: 'eslint-plugin-reamo',
    version: '1.0.0',
  },
  rules: {
    /**
     * Require cleanup for timers/listeners in useEffect
     *
     * Detects setTimeout/setInterval/addEventListener/requestAnimationFrame in useEffect
     * and warns if no cleanup function is returned.
     *
     * @see FRONTEND_DEVELOPMENT.md §4 Memory Safety
     */
    'require-effect-cleanup': {
      meta: {
        type: 'problem',
        docs: {
          description: 'Require cleanup for timers/listeners in useEffect',
          recommended: true,
        },
        messages: {
          missingCleanup:
            'useEffect with {{pattern}} should return a cleanup function. See FRONTEND_DEVELOPMENT.md §4.',
        },
        schema: [],
      },
      create(context) {
        const patternsNeedingCleanup = [
          'setTimeout',
          'setInterval',
          'addEventListener',
          'requestAnimationFrame',
        ];

        return {
          "CallExpression[callee.name='useEffect']"(node) {
            const callback = node.arguments[0];
            if (
              !callback ||
              !['ArrowFunctionExpression', 'FunctionExpression'].includes(callback.type)
            ) {
              return;
            }

            const sourceCode = context.sourceCode;
            const callbackText = sourceCode.getText(callback);

            for (const pattern of patternsNeedingCleanup) {
              if (callbackText.includes(pattern)) {
                // Check for return statement in the callback body
                const hasReturn =
                  callback.body.type === 'BlockStatement' &&
                  callback.body.body.some((stmt) => stmt.type === 'ReturnStatement');

                if (!hasReturn) {
                  context.report({
                    node: callback,
                    messageId: 'missingCleanup',
                    data: { pattern },
                  });
                  break; // Only report once per useEffect
                }
              }
            }
          },
        };
      },
    },

    /**
     * Prefer useRef over useState for timer IDs
     *
     * Timer IDs don't need to trigger re-renders. Using useState causes
     * unnecessary re-renders and can lead to stale closure issues.
     *
     * @see FRONTEND_DEVELOPMENT.md §4 Memory Safety - "useState vs useRef for Timers"
     */
    'no-state-for-timer-ids': {
      meta: {
        type: 'suggestion',
        docs: {
          description: 'Prefer useRef over useState for timer IDs',
          recommended: true,
        },
        messages: {
          useRefInstead:
            'Timer IDs should use useRef, not useState. useState causes re-renders and stale closures. See FRONTEND_DEVELOPMENT.md §4.',
        },
        schema: [],
      },
      create(context) {
        return {
          // Track useState declarations with timer-like names
          "VariableDeclarator[init.callee.name='useState']"(node) {
            const id = node.id;
            if (id.type !== 'ArrayPattern' || id.elements.length < 2) return;

            const stateName = id.elements[0]?.name?.toLowerCase() || '';

            // Heuristic: names containing timer, timeout, interval, animation, raf
            if (/timer|timeout|interval|animation|raf/i.test(stateName)) {
              context.report({
                node,
                messageId: 'useRefInstead',
              });
            }
          },
        };
      },
    },

    /**
     * Prefer design system button components over raw <button>
     *
     * Encourages using CircularTransportButton, ModalFooter, track button patterns
     * instead of ad-hoc button implementations.
     *
     * @see FRONTEND_DEVELOPMENT.md §1a Button System
     */
    'prefer-button-primitive': {
      meta: {
        type: 'suggestion',
        docs: {
          description: 'Prefer design system button components over raw <button>',
          recommended: false,
        },
        messages: {
          preferPrimitive:
            'Prefer design system buttons (CircularTransportButton, ModalFooter, track buttons). See FRONTEND_DEVELOPMENT.md §1a.',
        },
        schema: [],
      },
      create(context) {
        return {
          "JSXOpeningElement[name.name='button']"(node) {
            context.report({
              node,
              messageId: 'preferPrimitive',
            });
          },
        };
      },
    },
  },
};

export default reamoRules;
