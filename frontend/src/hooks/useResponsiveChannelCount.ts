/**
 * Responsive Channel Count Hook
 * Returns the optimal number of mixer channels based on available width.
 * Follows Logic Remote patterns: 2-3 on phone, 6-8 on tablet.
 */

import { useState, useEffect, useMemo } from 'react';

/** Channel width in pixels (fader + meter + padding) */
const CHANNEL_WIDTH = 90;

/** Minimum padding on sides */
const MIN_PADDING = 16;

/** Width reserved for master track when shown */
const MASTER_TRACK_WIDTH = 70;

/** Breakpoints for channel count */
const CHANNEL_BREAKPOINTS = [
  { maxWidth: 400, channels: 2 },
  { maxWidth: 550, channels: 3 },
  { maxWidth: 700, channels: 4 },
  { maxWidth: 850, channels: 5 },
  { maxWidth: 1000, channels: 6 },
  { maxWidth: 1200, channels: 7 },
  { maxWidth: Infinity, channels: 8 },
];

export interface UseResponsiveChannelCountOptions {
  /** Container element to measure (default: window) */
  containerRef?: React.RefObject<HTMLElement | null>;
  /** Whether master track is pinned (shown separately, reserving space) */
  masterPinned?: boolean;
}

export interface UseResponsiveChannelCountReturn {
  /** Number of channels that fit in available width */
  channelCount: number;
  /** Width available for channels */
  availableWidth: number;
}

/**
 * Calculate optimal channel count based on available width.
 * Uses breakpoints similar to Logic Remote's responsive behavior.
 */
export function useResponsiveChannelCount(
  options: UseResponsiveChannelCountOptions = {}
): UseResponsiveChannelCountReturn {
  const { containerRef, masterPinned = true } = options;

  // Track container width for resize reactivity
  const [containerWidth, setContainerWidth] = useState(() => {
    return containerRef?.current?.clientWidth ?? window.innerWidth;
  });

  // Listen for resize events
  useEffect(() => {
    const handleResize = () => {
      const width = containerRef?.current?.clientWidth ?? window.innerWidth;
      setContainerWidth(width);
    };

    // Initial measurement
    handleResize();

    window.addEventListener('resize', handleResize);

    let resizeObserver: ResizeObserver | null = null;
    if (containerRef?.current) {
      resizeObserver = new ResizeObserver(handleResize);
      resizeObserver.observe(containerRef.current);
    }

    return () => {
      window.removeEventListener('resize', handleResize);
      resizeObserver?.disconnect();
    };
  }, [containerRef]);

  // Calculate channel count synchronously from current width and masterPinned
  // This avoids the two-phase render that causes flicker
  const result = useMemo((): UseResponsiveChannelCountReturn => {
    const rawWidth = containerWidth;

    // Reserve space for pinned master and padding
    const masterSpace = masterPinned ? MASTER_TRACK_WIDTH : 0;
    const availableWidth = rawWidth - masterSpace - MIN_PADDING * 2;

    // Use breakpoints with available width
    const breakpoint = CHANNEL_BREAKPOINTS.find(bp => rawWidth <= bp.maxWidth);
    let breakpointChannels = breakpoint?.channels ?? 8;

    // When master isn't pinned, we can fit one extra channel in its space
    if (!masterPinned) {
      breakpointChannels += 1;
    }

    // Also calculate based on actual fit
    const fittedChannels = Math.floor(availableWidth / CHANNEL_WIDTH);

    // Use whichever is smaller (breakpoint or actual fit)
    const channelCount = Math.max(2, Math.min(breakpointChannels, fittedChannels));

    return { channelCount, availableWidth };
  }, [containerWidth, masterPinned]);

  return result;
}
