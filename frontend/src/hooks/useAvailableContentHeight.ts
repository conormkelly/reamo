/**
 * useAvailableContentHeight - Measures available height in ViewLayout content area
 *
 * Uses ResizeObserver to track container height changes. Waits for panel
 * transitions to complete before reporting new values to avoid jank.
 *
 * @see RESPONSIVE_TIMELINE_AND_MIXER.md for architecture decisions
 */

import { useState, useEffect, useRef, type RefObject } from 'react';
import { useReaperStore } from '../store';
import { useIsLandscape } from './useMediaQuery';
import { useReducedMotion } from './useReducedMotion';
import { PANEL_TRANSITION_MS } from '../constants/layout';

export interface UseAvailableContentHeightOptions {
  /** Ref to the content container element */
  containerRef: RefObject<HTMLElement | null>;
  /** View ID for panel state lookup */
  viewId: 'mixer' | 'timeline';
}

export interface UseAvailableContentHeightReturn {
  /** Measured height of content area in pixels */
  availableHeight: number;
  /** Whether we're in landscape orientation */
  isLandscape: boolean;
  /** True while panel is animating (heights may be stale) */
  isTransitioning: boolean;
}

/**
 * Measures available content height and tracks orientation/transition state.
 *
 * The hook returns the container's clientHeight, which is the space available
 * for content ABOVE the SecondaryPanel. Views subtract their overhead constants
 * from this value to get the actual fader/timeline height.
 */
export function useAvailableContentHeight(
  options: UseAvailableContentHeightOptions
): UseAvailableContentHeightReturn {
  const { containerRef, viewId } = options;

  // Track container height
  const [availableHeight, setAvailableHeight] = useState(0);

  // Track transition state
  const [isTransitioning, setIsTransitioning] = useState(false);
  const transitionTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  // Get panel state and orientation
  const panelExpanded = useReaperStore((s) => s.secondaryPanelExpanded[viewId]);
  const isLandscape = useIsLandscape();
  const prefersReducedMotion = useReducedMotion();

  // Track previous panel state to detect changes
  const prevPanelExpandedRef = useRef(panelExpanded);

  // Cleanup timer on unmount
  useEffect(() => {
    return () => {
      if (transitionTimerRef.current) {
        clearTimeout(transitionTimerRef.current);
        transitionTimerRef.current = null;
      }
    };
  }, []);

  // Handle panel expand/collapse transitions
  useEffect(() => {
    // Skip if panel state hasn't changed
    if (prevPanelExpandedRef.current === panelExpanded) {
      return;
    }
    prevPanelExpandedRef.current = panelExpanded;

    // Skip transition delay if user prefers reduced motion
    if (prefersReducedMotion) {
      return;
    }

    // Clear any existing timer
    if (transitionTimerRef.current) {
      clearTimeout(transitionTimerRef.current);
      transitionTimerRef.current = null;
    }

    // Mark as transitioning
    setIsTransitioning(true);

    // Clear transition state after animation completes
    transitionTimerRef.current = setTimeout(() => {
      transitionTimerRef.current = null;
      setIsTransitioning(false);
    }, PANEL_TRANSITION_MS);
  }, [panelExpanded, prefersReducedMotion]);

  // ResizeObserver for container height measurement
  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    const updateHeight = () => {
      const height = container.clientHeight;
      setAvailableHeight(height);
    };

    // Initial measurement
    updateHeight();

    // Observe size changes (orientation, keyboard, etc.)
    const resizeObserver = new ResizeObserver(() => {
      // Use RAF to batch with paint
      requestAnimationFrame(updateHeight);
    });
    resizeObserver.observe(container);

    // Also listen for window resize as fallback
    window.addEventListener('resize', updateHeight);

    return () => {
      resizeObserver.disconnect();
      window.removeEventListener('resize', updateHeight);
    };
  }, [containerRef]);

  return {
    availableHeight,
    isLandscape,
    isTransitioning,
  };
}
