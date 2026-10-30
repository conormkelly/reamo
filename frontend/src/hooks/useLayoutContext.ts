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
 * Two questions, two signals. "Is the device on its side?" comes from the
 * device (screen.orientation), which neither the on-screen keyboard nor a
 * browser that leaves its viewport short can change. "How much room is
 * there?" comes from the viewport. Reading orientation from the viewport's
 * shape would put an upright phone into the side rail whenever its viewport
 * is shortened, and the switch remounts the view, closing any open dialog.
 *
 * Every consumer reads one shared store, so they always agree, including
 * a consumer that mounts while the keyboard is up.
 *
 * @see docs/architecture/frontend/RESPONSIVE_FRONTEND_FINAL.md
 */

import { useSyncExternalStore } from 'react';
import {
  HEIGHT_COMPACT_THRESHOLD,
  WIDTH_EXPANDED_THRESHOLD,
  WIDTH_MEDIUM_THRESHOLD,
} from '../constants/layout';

// =============================================================================
// Types
// =============================================================================

/** Width size class based on Material Design breakpoints */
export type WidthClass = 'compact' | 'medium' | 'expanded';

/** Height size class - compact triggers special landscape handling */
export type HeightClass = 'compact' | 'regular';

/** Navigation position - side rail for landscape-constrained phones */
export type NavPosition = 'bottom' | 'side';

/** Which way up the device is held; 'unknown' without screen.orientation. */
export type DeviceOrientation = 'portrait' | 'landscape' | 'unknown';

/** Complete layout context returned by the hook */
export interface LayoutContext {
  /** Width class: compact (<600px), medium (600-839px), expanded (>=840px) */
  widthClass: WidthClass;
  /** Height class: compact (<480px), regular (>=480px) */
  heightClass: HeightClass;
  /** True when the device is on its side and the viewport is wider than tall */
  isLandscape: boolean;
  /** True when landscape AND height < 480px (landscape phone) */
  isLandscapeConstrained: boolean;
  /** Navigation position: 'side' when landscape-constrained, else 'bottom' */
  navPosition: NavPosition;
  /** Raw viewport dimensions for advanced use cases */
  viewport: { width: number; height: number };
}

// =============================================================================
// Classification
// =============================================================================

/**
 * The layout for a viewport on a device held a given way up.
 *
 * Landscape needs both the device on its side and a viewport wider than
 * tall: a narrow Slide Over or split-screen window on a landscape iPad is
 * portrait-shaped and keeps bottom navigation. Without screen.orientation,
 * the viewport's shape decides alone.
 */
export function classifyLayout(
  viewport: { width: number; height: number },
  device: DeviceOrientation,
): LayoutContext {
  const { width, height } = viewport;

  const widthClass: WidthClass =
    width >= WIDTH_EXPANDED_THRESHOLD
      ? 'expanded'
      : width >= WIDTH_MEDIUM_THRESHOLD
        ? 'medium'
        : 'compact';

  const heightClass: HeightClass = height < HEIGHT_COMPACT_THRESHOLD ? 'compact' : 'regular';

  const viewportLandscape = width > height;
  const isLandscape = device === 'unknown' ? viewportLandscape : device === 'landscape' && viewportLandscape;

  // Tablets have regular height even in landscape, so they keep bottom nav.
  const isLandscapeConstrained = isLandscape && heightClass === 'compact';

  return {
    widthClass,
    heightClass,
    isLandscape,
    isLandscapeConstrained,
    navPosition: isLandscapeConstrained ? 'side' : 'bottom',
    viewport,
  };
}

// =============================================================================
// Shared store
// =============================================================================

function readDeviceOrientation(): DeviceOrientation {
  const type = typeof screen === 'undefined' ? undefined : screen.orientation?.type;
  if (!type) return 'unknown';
  return type.startsWith('portrait') ? 'portrait' : 'landscape';
}

/** Input types that bring up the on-screen keyboard. */
const KEYBOARD_INPUT_TYPES = new Set([
  'text', 'search', 'email', 'url', 'tel', 'password', 'number',
]);

/**
 * Whether the focused element is one the on-screen keyboard opens for.
 */
function isEditingText(): boolean {
  const el = document.activeElement;
  if (el instanceof HTMLTextAreaElement) return true;
  if (el instanceof HTMLInputElement) return KEYBOARD_INPUT_TYPES.has(el.type);
  return el instanceof HTMLElement && el.isContentEditable;
}

/** SSR fallback - assume an upright phone */
const SERVER_LAYOUT = classifyLayout({ width: 375, height: 667 }, 'portrait');

let current: LayoutContext | null = null;
let currentDevice: DeviceOrientation = 'unknown';
let watchedOrientation: ScreenOrientation | undefined;
const listeners = new Set<() => void>();

/** Re-read the viewport and device; returns whether the layout changed. */
function refresh(): boolean {
  const width = window.innerWidth;
  const height = window.innerHeight;
  const device = readDeviceOrientation();

  if (current) {
    const prev = current.viewport;
    if (device === currentDevice && width === prev.width && height === prev.height) return false;
    // The on-screen keyboard changes only the height, and only while a text
    // field has focus. Following it could take a landscape tablet under the
    // side-rail height while someone types.
    if (device === currentDevice && width === prev.width && isEditingText()) return false;
  }

  currentDevice = device;
  current = classifyLayout({ width, height }, device);
  return true;
}

function handleChange() {
  if (refresh()) listeners.forEach((listener) => listener());
}

function subscribe(listener: () => void): () => void {
  if (listeners.size === 0) {
    // Nothing tracked the viewport while there were no subscribers.
    refresh();
    window.addEventListener('resize', handleChange);
    watchedOrientation = typeof screen === 'undefined' ? undefined : screen.orientation;
    watchedOrientation?.addEventListener('change', handleChange);
  }
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
    if (listeners.size === 0) {
      window.removeEventListener('resize', handleChange);
      watchedOrientation?.removeEventListener('change', handleChange);
      watchedOrientation = undefined;
    }
  };
}

function getSnapshot(): LayoutContext {
  if (!current) refresh();
  return current!;
}

function getServerSnapshot(): LayoutContext {
  return SERVER_LAYOUT;
}

// =============================================================================
// Hook
// =============================================================================

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
  return useSyncExternalStore(subscribe, getSnapshot, getServerSnapshot);
}

/**
 * Whether the device is on its side with a landscape-shaped viewport.
 *
 * Use this rather than an (orientation: landscape) media query: the media
 * query follows the viewport's shape, so the on-screen keyboard flips it on
 * an upright phone.
 */
export function useIsLandscape(): boolean {
  return useLayoutContext().isLandscape;
}
