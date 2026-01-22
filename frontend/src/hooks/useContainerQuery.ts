/**
 * useContainerQuery - React hook for container-based responsive behavior
 *
 * Uses ResizeObserver to detect container width changes, enabling
 * component-local responsive behavior independent of viewport size.
 *
 * @see docs/architecture/UX_GUIDELINES.md §8 (Header Overflow Pattern)
 */

import { useState, useEffect, type RefObject } from 'react';

/**
 * Hook to detect if a container is narrower than a breakpoint
 *
 * @param containerRef - Ref to the container element to observe
 * @param breakpoint - Width threshold in pixels
 * @returns true when container width is less than breakpoint
 *
 * @example
 * const containerRef = useRef<HTMLDivElement>(null);
 * const isNarrow = useContainerQuery(containerRef, 400);
 *
 * return (
 *   <div ref={containerRef}>
 *     {isNarrow ? <CompactView /> : <FullView />}
 *   </div>
 * );
 */
export function useContainerQuery(
  containerRef: RefObject<HTMLElement | null>,
  breakpoint: number
): boolean {
  const [isNarrow, setIsNarrow] = useState(false);

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    // Initial measurement
    setIsNarrow(container.offsetWidth < breakpoint);

    const observer = new ResizeObserver((entries) => {
      for (const entry of entries) {
        setIsNarrow(entry.contentRect.width < breakpoint);
      }
    });

    observer.observe(container);
    return () => observer.disconnect();
  }, [containerRef, breakpoint]);

  return isNarrow;
}
