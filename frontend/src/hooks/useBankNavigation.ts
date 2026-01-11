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
  const { channelCount, totalTracks, storageKey = STORAGE_KEY } = options;

  // Calculate total banks
  const totalBanks = useMemo(() => {
    return Math.max(1, Math.ceil(totalTracks / channelCount));
  }, [totalTracks, channelCount]);

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

  // Calculate bank range (1-based track indices, excluding master)
  const bankStart = useMemo(() => {
    return bankIndex * channelCount + 1;
  }, [bankIndex, channelCount]);

  const bankEnd = useMemo(() => {
    return Math.min((bankIndex + 1) * channelCount, totalTracks);
  }, [bankIndex, channelCount, totalTracks]);

  // Generate track indices
  const trackIndices = useMemo(() => {
    const indices: number[] = [];
    for (let i = bankStart; i <= bankEnd; i++) {
      indices.push(i);
    }
    return indices;
  }, [bankStart, bankEnd]);

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

  // Display string
  const bankDisplay = useMemo(() => {
    if (totalTracks === 0) return 'No tracks';
    return `${bankStart}-${bankEnd} of ${totalTracks}`;
  }, [bankStart, bankEnd, totalTracks]);

  return {
    bankIndex,
    bankStart,
    bankEnd,
    trackIndices,
    totalBanks,
    canGoBack,
    canGoForward,
    goBack,
    goForward,
    goToBank,
    bankDisplay,
  };
}
