/**
 * useLayoutContext - Size class detection for responsive layouts
 *
 * Provides layout context including width/height size classes and navigation position.
 * Used to switch between bottom navigation (portrait) and side rail (landscape phones).
 *
 * Size Classes:
 * - Width: compact (<600px), medium (600-839px), expanded (>=840px)
 * - Height: compact (<480px), regular (>=480px)
 *
 * Navigation Position:
 * - 'bottom': Standard bottom TabBar + Transport (default)
 * - 'side': Side rail with nav + transport (landscape phones only)
 *
 * @see docs/architecture/RESPONSIVE_FRONTEND_FINAL.md
 */

import { useState, useEffect, useMemo } from 'react';

// =============================================================================
// Types
// =============================================================================

/** Width size class based on Material Design breakpoints */
export type WidthClass = 'compact' | 'medium' | 'expanded';

/** Height size class - compact triggers special landscape handling */
export type HeightClass = 'compact' | 'regular';

/** Navigation position - side rail for landscape-constrained phones */
export type NavPosition = 'bottom' | 'side';

/** Complete layout context returned by the hook */
export interface LayoutContext {
  /** Width class: compact (<600px), medium (600-839px), expanded (>=840px) */
  widthClass: WidthClass;
  /** Height class: compact (<480px), regular (>=480px) */
  heightClass: HeightClass;
  /** True when width > height AND height < 480px (landscape phone) */
  isLandscapeConstrained: boolean;
  /** Navigation position: 'side' when landscape-constrained, else 'bottom' */
  navPosition: NavPosition;
  /** Raw viewport dimensions for advanced use cases */
  viewport: { width: number; height: number };
}

// =============================================================================
// Constants (also exported from constants/layout.ts)
// =============================================================================

/** Width threshold for medium size class (Material Design) */
const WIDTH_MEDIUM = 600;

/** Width threshold for expanded size class (Material Design) */
const WIDTH_EXPANDED = 840;

/** Height threshold below which we consider height "compact" */
const HEIGHT_COMPACT = 480;

// =============================================================================
// Hook Implementation
// =============================================================================

/**
 * Get initial viewport dimensions (SSR-safe)
 */
function getInitialViewport(): { width: number; height: number } {
  if (typeof window === 'undefined') {
    // SSR fallback - assume portrait phone
    return { width: 375, height: 667 };
  }
  return {
    width: window.innerWidth,
    height: window.innerHeight,
  };
}

/**
 * Hook to detect layout context including size classes and navigation position
 *
 * @returns LayoutContext with size classes, nav position, and viewport dimensions
 *
 * @example
 * const { navPosition, isLandscapeConstrained } = useLayoutContext();
 *
 * // Conditional rendering based on nav position
 * {navPosition === 'side' ? <SideRail /> : <TabBar />}
 *
 * // Adjust view behavior for landscape-constrained
 * const showSecondaryPanel = !isLandscapeConstrained;
 */
export function useLayoutContext(): LayoutContext {
  const [viewport, setViewport] = useState(getInitialViewport);

  useEffect(() => {
    const updateViewport = () => {
      setViewport({
        width: window.innerWidth,
        height: window.innerHeight,
      });
    };

    // Update in case SSR hydration differs from client
    updateViewport();

    // Listen for resize events
    window.addEventListener('resize', updateViewport);

    // Also listen for orientation change (mobile Safari sometimes misses resize)
    window.addEventListener('orientationchange', updateViewport);

    return () => {
      window.removeEventListener('resize', updateViewport);
      window.removeEventListener('orientationchange', updateViewport);
    };
  }, []);

  return useMemo(() => {
    const { width, height } = viewport;

    // Determine width class (Material Design breakpoints)
    const widthClass: WidthClass =
      width >= WIDTH_EXPANDED
        ? 'expanded'
        : width >= WIDTH_MEDIUM
          ? 'medium'
          : 'compact';

    // Determine height class
    const heightClass: HeightClass = height < HEIGHT_COMPACT ? 'compact' : 'regular';

    // Landscape-constrained: phone in landscape with very limited height
    // Must be wider than tall AND have compact height
    // This specifically targets phones in landscape, not tablets
    const isLandscapeConstrained = width > height && height < HEIGHT_COMPACT;

    // Navigation moves to side rail only when landscape-constrained
    // Tablets (which have regular height even in landscape) keep bottom nav
    const navPosition: NavPosition = isLandscapeConstrained ? 'side' : 'bottom';

    return {
      widthClass,
      heightClass,
      isLandscapeConstrained,
      navPosition,
      viewport,
    };
  }, [viewport]);
}
