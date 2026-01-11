/**
 * Responsive Channel Count Hook
 * Returns the optimal number of mixer channels based on available width.
 * Follows Logic Remote patterns: 2-3 on phone, 6-8 on tablet.
 */

import { useState, useEffect, useCallback } from 'react';

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
  /** Whether to reserve space for master track */
  showMaster?: boolean;
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
  const { containerRef, showMaster = true } = options;

  const calculateChannelCount = useCallback((): UseResponsiveChannelCountReturn => {
    const container = containerRef?.current;
    const rawWidth = container ? container.clientWidth : window.innerWidth;

    // Reserve space for master and padding
    const masterSpace = showMaster ? MASTER_TRACK_WIDTH : 0;
    const availableWidth = rawWidth - masterSpace - MIN_PADDING * 2;

    // Use breakpoints with available width
    const breakpoint = CHANNEL_BREAKPOINTS.find(bp => rawWidth <= bp.maxWidth);
    const breakpointChannels = breakpoint?.channels ?? 8;

    // Also calculate based on actual fit
    const fittedChannels = Math.floor(availableWidth / CHANNEL_WIDTH);

    // Use whichever is smaller (breakpoint or actual fit)
    const channelCount = Math.max(2, Math.min(breakpointChannels, fittedChannels));

    return { channelCount, availableWidth };
  }, [containerRef, showMaster]);

  const [state, setState] = useState<UseResponsiveChannelCountReturn>(calculateChannelCount);

  useEffect(() => {
    const handleResize = () => {
      setState(calculateChannelCount());
    };

    // Initial calculation
    handleResize();

    // Listen for resize
    window.addEventListener('resize', handleResize);

    // Also observe container if provided
    let resizeObserver: ResizeObserver | null = null;
    if (containerRef?.current) {
      resizeObserver = new ResizeObserver(handleResize);
      resizeObserver.observe(containerRef.current);
    }

    return () => {
      window.removeEventListener('resize', handleResize);
      resizeObserver?.disconnect();
    };
  }, [calculateChannelCount, containerRef]);

  return state;
}
