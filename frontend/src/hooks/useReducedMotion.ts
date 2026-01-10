import { useState, useEffect } from 'react';

/**
 * Hook to detect user's motion preferences.
 * Returns true if user prefers reduced motion.
 *
 * Use for runtime behavior changes (momentum, zoom animation duration).
 * CSS handles most cases via @media query in index.css.
 *
 * @example
 * const prefersReducedMotion = useReducedMotion();
 * const scrollBehavior = prefersReducedMotion ? 'instant' : 'smooth';
 */
export function useReducedMotion(): boolean {
  const [prefersReducedMotion, setPrefersReducedMotion] = useState(() => {
    // SSR safety: check if window exists
    if (typeof window === 'undefined') return false;
    return window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  });

  useEffect(() => {
    const mediaQuery = window.matchMedia('(prefers-reduced-motion: reduce)');

    const handleChange = (event: MediaQueryListEvent) => {
      setPrefersReducedMotion(event.matches);
    };

    // Modern browsers
    mediaQuery.addEventListener('change', handleChange);

    return () => {
      mediaQuery.removeEventListener('change', handleChange);
    };
  }, []);

  return prefersReducedMotion;
}
