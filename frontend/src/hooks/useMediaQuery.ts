/**
 * useMediaQuery - React hook for responsive media query detection
 *
 * Provides reactive media query matching with proper SSR handling and cleanup.
 *
 * @see docs/architecture/UX_GUIDELINES.md §7, §8, §9
 */

import { useState, useEffect } from 'react';

/**
 * Hook to reactively match a media query
 *
 * @param query - CSS media query string (e.g., '(orientation: landscape)')
 * @returns boolean indicating if the media query matches
 *
 * @example
 * const isWide = useMediaQuery('(min-width: 768px)');
 * const isPWA = useMediaQuery('(display-mode: standalone)');
 */
export function useMediaQuery(query: string): boolean {
  const [matches, setMatches] = useState(() => {
    if (typeof window === 'undefined') return false;
    return window.matchMedia(query).matches;
  });

  useEffect(() => {
    const mediaQuery = window.matchMedia(query);
    const handler = (e: MediaQueryListEvent) => setMatches(e.matches);

    // Set initial value in case it changed between SSR and hydration
    setMatches(mediaQuery.matches);

    mediaQuery.addEventListener('change', handler);
    return () => mediaQuery.removeEventListener('change', handler);
  }, [query]);

  return matches;
}

// Convenience exports for common queries

/**
 * Hook to detect landscape orientation
 * @returns true when device is in landscape mode
 */
export const useIsLandscape = () => useMediaQuery('(orientation: landscape)');

/**
 * Hook to detect portrait orientation
 * @returns true when device is in portrait mode
 */
export const useIsPortrait = () => useMediaQuery('(orientation: portrait)');

/**
 * Hook to detect PWA standalone mode
 * @returns true when running as installed PWA (not in browser)
 */
export const useIsPWA = () => useMediaQuery('(display-mode: standalone)');
