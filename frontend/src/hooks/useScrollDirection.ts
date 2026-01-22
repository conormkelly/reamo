/**
 * useScrollDirection - React hook to detect scroll direction
 *
 * Enables auto-hide behavior for navigation elements (future use).
 * Uses requestAnimationFrame for performance-safe scroll handling.
 *
 * @see docs/architecture/UX_GUIDELINES.md §7 (Footer Chrome Strategy)
 */

import { useState, useEffect, type RefObject } from 'react';

export type ScrollDirection = 'up' | 'down' | null;

export interface UseScrollDirectionReturn {
  /** Current scroll direction */
  direction: ScrollDirection;
  /** Whether scroll position is at or near the top */
  isAtTop: boolean;
}

/**
 * Hook to detect scroll direction within a container or window
 *
 * @param scrollRef - Optional ref to scroll container. If not provided, uses window.
 * @returns Object with direction ('up' | 'down' | null) and isAtTop boolean
 *
 * @example
 * // Auto-hide footer on scroll down
 * const { direction, isAtTop } = useScrollDirection();
 * const showFooter = direction === 'up' || isAtTop;
 *
 * @example
 * // Track scroll in a specific container
 * const scrollRef = useRef<HTMLDivElement>(null);
 * const { direction } = useScrollDirection(scrollRef);
 */
export function useScrollDirection(
  scrollRef?: RefObject<HTMLElement | null>
): UseScrollDirectionReturn {
  const [direction, setDirection] = useState<ScrollDirection>(null);
  const [isAtTop, setIsAtTop] = useState(true);

  useEffect(() => {
    const target = scrollRef?.current ?? window;
    let lastScrollY = 0;
    let ticking = false;

    const updateScrollDir = () => {
      const scrollY = scrollRef?.current?.scrollTop ?? window.scrollY;

      // Ignore small movements (prevents jitter from overscroll bounce)
      if (Math.abs(scrollY - lastScrollY) < 10) {
        ticking = false;
        return;
      }

      setDirection(scrollY > lastScrollY ? 'down' : 'up');
      setIsAtTop(scrollY < 10);
      lastScrollY = scrollY;
      ticking = false;
    };

    const onScroll = () => {
      if (!ticking) {
        requestAnimationFrame(updateScrollDir);
        ticking = true;
      }
    };

    target.addEventListener('scroll', onScroll, { passive: true });
    return () => target.removeEventListener('scroll', onScroll);
  }, [scrollRef]);

  return { direction, isAtTop };
}
