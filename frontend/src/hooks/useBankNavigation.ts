/**
 * Bank Navigation Hook
 * Manages discrete bank-based navigation for mixer channels.
 * Banks move by channelCount (e.g., tracks 1-8, 9-16, 17-24).
 */

import { useState, useCallback, useMemo, useEffect } from 'react';

export interface UseBankNavigationOptions {
  /** Number of channels per bank */
  channelCount: number;
  /** Total number of tracks (excluding master) */
  totalTracks: number;
  /** Include master track (index 0) in bank navigation. Default: false */
  includeMaster?: boolean;
  /** Optional: override localStorage key for persistence */
  storageKey?: string;
}

export interface UseBankNavigationReturn {
  /** Current bank index (0-based) */
  bankIndex: number;
  /** First track index in current bank (1-based, excludes master) */
  bankStart: number;
  /** Last track index in current bank (1-based, clamped to totalTracks) */
  bankEnd: number;
  /** Track indices in current bank */
  trackIndices: number[];
  /** Prefetch range start (includes adjacent banks for smooth navigation) */
  prefetchStart: number;
  /** Prefetch range end (includes adjacent banks for smooth navigation) */
  prefetchEnd: number;
  /** Total number of banks */
  totalBanks: number;
  /** Can navigate to previous bank */
  canGoBack: boolean;
  /** Can navigate to next bank */
  canGoForward: boolean;
  /** Go to previous bank */
  goBack: () => void;
  /** Go to next bank */
  goForward: () => void;
  /** Go to specific bank */
  goToBank: (index: number) => void;
  /** Bank display string (e.g., "1-8 of 24") */
  bankDisplay: string;
}

const STORAGE_KEY = 'reamo-mixer-bank';

/**
 * Manage bank-based channel navigation.
 * Persists current bank to localStorage.
 */
export function useBankNavigation(
  options: UseBankNavigationOptions
): UseBankNavigationReturn {
  const { channelCount, totalTracks, includeMaster = false, storageKey = STORAGE_KEY } = options;

  // When master is included in banks, we have totalTracks + 1 tracks to navigate
  // Track indices: 0 (master), 1, 2, ... totalTracks
  // When master is NOT included, we navigate tracks 1 to totalTracks
  const trackableCount = includeMaster ? totalTracks + 1 : totalTracks;
  const startIndex = includeMaster ? 0 : 1;

  // Calculate total banks
  const totalBanks = useMemo(() => {
    return Math.max(1, Math.ceil(trackableCount / channelCount));
  }, [trackableCount, channelCount]);

  // Load initial bank from localStorage
  const [bankIndex, setBankIndex] = useState<number>(() => {
    try {
      const stored = localStorage.getItem(storageKey);
      if (stored) {
        const parsed = parseInt(stored, 10);
        if (!isNaN(parsed) && parsed >= 0) {
          return parsed;
        }
      }
    } catch {
      // Ignore localStorage errors
    }
    return 0;
  });

  // Clamp bank index when totalBanks changes
  useEffect(() => {
    if (bankIndex >= totalBanks) {
      setBankIndex(Math.max(0, totalBanks - 1));
    }
  }, [bankIndex, totalBanks]);

  // Persist to localStorage
  useEffect(() => {
    try {
      localStorage.setItem(storageKey, String(bankIndex));
    } catch {
      // Ignore localStorage errors
    }
  }, [bankIndex, storageKey]);

  // Calculate bank range
  // When includeMaster: indices 0, 1, 2, ... (startIndex = 0)
  // When !includeMaster: indices 1, 2, 3, ... (startIndex = 1)
  const bankStart = useMemo(() => {
    return bankIndex * channelCount + startIndex;
  }, [bankIndex, channelCount, startIndex]);

  const bankEnd = useMemo(() => {
    // End index is clamped to the last valid track index (totalTracks)
    return Math.min(bankStart + channelCount - 1, totalTracks);
  }, [bankStart, channelCount, totalTracks]);

  // Generate track indices
  const trackIndices = useMemo(() => {
    const indices: number[] = [];
    for (let i = bankStart; i <= bankEnd; i++) {
      indices.push(i);
    }
    return indices;
  }, [bankStart, bankEnd]);

  // Calculate prefetch range - subscribe to adjacent banks for smooth navigation
  // Smaller banks (mobile) need more prefetched banks, larger banks need fewer
  const { prefetchStart, prefetchEnd } = useMemo(() => {
    // Prefetch enough tracks to cover 2-4 banks on each side
    // Mobile (2-3 channels): 4 banks each side = 8-12 tracks
    // Tablet (4-6 channels): 2 banks each side = 8-12 tracks
    // Desktop (7-8 channels): 1-2 banks each side = 7-16 tracks
    const prefetchBanks = channelCount <= 3 ? 4 : channelCount <= 6 ? 2 : 1;
    const prefetchTracks = prefetchBanks * channelCount;

    return {
      prefetchStart: Math.max(startIndex, bankStart - prefetchTracks),
      prefetchEnd: Math.min(totalTracks, bankEnd + prefetchTracks),
    };
  }, [bankStart, bankEnd, channelCount, totalTracks, startIndex]);

  // Navigation state
  const canGoBack = bankIndex > 0;
  const canGoForward = bankIndex < totalBanks - 1;

  // Navigation actions
  const goBack = useCallback(() => {
    if (canGoBack) {
      setBankIndex((prev) => prev - 1);
    }
  }, [canGoBack]);

  const goForward = useCallback(() => {
    if (canGoForward) {
      setBankIndex((prev) => prev + 1);
    }
  }, [canGoForward]);

  const goToBank = useCallback(
    (index: number) => {
      const clampedIndex = Math.max(0, Math.min(index, totalBanks - 1));
      setBankIndex(clampedIndex);
    },
    [totalBanks]
  );

  // Display string - shows track index range
  const bankDisplay = useMemo(() => {
    if (trackableCount === 0) return 'No tracks';
    return `${bankStart}-${bankEnd} / ${trackableCount}`;
  }, [bankStart, bankEnd, trackableCount]);

  return {
    bankIndex,
    bankStart,
    bankEnd,
    trackIndices,
    prefetchStart,
    prefetchEnd,
    totalBanks,
    canGoBack,
    canGoForward,
    goBack,
    goForward,
    goToBank,
    bankDisplay,
  };
}
