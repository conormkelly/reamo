/**
 * lint-staged configuration for REAmo frontend
 *
 * Runs ESLint on staged files before commit to catch issues early.
 * Uses --cache for performance (<2 second target for typical commits).
 *
 * @see docs/architecture/ESLINT_GOVERNANCE.md
 */

export default {
  // TypeScript/React files - lint and fix
  '*.{ts,tsx}': [
    'eslint --cache --cache-location node_modules/.cache/.eslintcache --fix --max-warnings=0',
  ],
};
