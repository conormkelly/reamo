/**
 * Tests for useBankNavigation — bank math, boundary clamping, navigation, display strings.
 */

import { describe, it, expect, beforeAll, beforeEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { useBankNavigation } from './useBankNavigation';

// Node 25+ localStorage shim
beforeAll(() => {
  const store = new Map<string, string>();
  Object.defineProperty(globalThis, 'localStorage', {
    value: {
      getItem: (key: string) => store.get(key) ?? null,
      setItem: (key: string, value: string) => store.set(key, String(value)),
      removeItem: (key: string) => store.delete(key),
      clear: () => store.clear(),
      get length() { return store.size; },
      key: (i: number) => [...store.keys()][i] ?? null,
    },
    configurable: true,
    writable: true,
  });
});

beforeEach(() => {
  localStorage.clear();
});

describe('useBankNavigation', () => {
  // ===========================================================================
  // Bank calculation
  // ===========================================================================

  describe('bank math', () => {
    it('calculates totalBanks from totalTracks and channelCount', () => {
      const { result } = renderHook(() =>
        useBankNavigation({ channelCount: 8, totalTracks: 24 })
      );
      expect(result.current.totalBanks).toBe(3); // 24 / 8 = 3
    });

    it('rounds up partial banks', () => {
      const { result } = renderHook(() =>
        useBankNavigation({ channelCount: 8, totalTracks: 25 })
      );
      expect(result.current.totalBanks).toBe(4); // ceil(25/8) = 4
    });

    it('returns at least 1 bank when no tracks', () => {
      const { result } = renderHook(() =>
        useBankNavigation({ channelCount: 8, totalTracks: 0 })
      );
      expect(result.current.totalBanks).toBe(1);
    });

    it('computes trackIndices for first bank (no master)', () => {
      const { result } = renderHook(() =>
        useBankNavigation({ channelCount: 4, totalTracks: 10 })
      );
      // Without master: start=1, indices 1-4
      expect(result.current.bankStart).toBe(1);
      expect(result.current.bankEnd).toBe(4);
      expect(result.current.trackIndices).toEqual([1, 2, 3, 4]);
    });

    it('computes trackIndices for first bank (includeMaster)', () => {
      const { result } = renderHook(() =>
        useBankNavigation({ channelCount: 4, totalTracks: 10, includeMaster: true })
      );
      // With master: start=0, indices 0-3
      expect(result.current.bankStart).toBe(0);
      expect(result.current.bankEnd).toBe(3);
      expect(result.current.trackIndices).toEqual([0, 1, 2, 3]);
    });

    it('clamps bankEnd to totalTracks on last bank', () => {
      const { result } = renderHook(() =>
        useBankNavigation({ channelCount: 8, totalTracks: 5 })
      );
      // Bank 0: start=1, end=min(8, 5) = 5
      expect(result.current.bankEnd).toBe(5);
      expect(result.current.trackIndices).toEqual([1, 2, 3, 4, 5]);
    });

    it('computes totalCount with includeMaster', () => {
      const { result } = renderHook(() =>
        useBankNavigation({ channelCount: 4, totalTracks: 10, includeMaster: true })
      );
      expect(result.current.totalCount).toBe(11); // 10 tracks + master
    });

    it('computes totalCount without master', () => {
      const { result } = renderHook(() =>
        useBankNavigation({ channelCount: 4, totalTracks: 10 })
      );
      expect(result.current.totalCount).toBe(10);
    });
  });

  // ===========================================================================
  // Navigation
  // ===========================================================================

  describe('navigation', () => {
    it('starts at bank 0', () => {
      const { result } = renderHook(() =>
        useBankNavigation({ channelCount: 4, totalTracks: 20 })
      );
      expect(result.current.bankIndex).toBe(0);
      expect(result.current.canGoBack).toBe(false);
      expect(result.current.canGoForward).toBe(true);
    });

    it('goForward advances bank', () => {
      const { result } = renderHook(() =>
        useBankNavigation({ channelCount: 4, totalTracks: 20 })
      );
      act(() => result.current.goForward());
      expect(result.current.bankIndex).toBe(1);
      expect(result.current.bankStart).toBe(5);
      expect(result.current.bankEnd).toBe(8);
    });

    it('goBack decrements bank', () => {
      const { result } = renderHook(() =>
        useBankNavigation({ channelCount: 4, totalTracks: 20 })
      );
      act(() => result.current.goForward());
      act(() => result.current.goForward());
      act(() => result.current.goBack());
      expect(result.current.bankIndex).toBe(1);
    });

    it('goForward is no-op at last bank', () => {
      const { result } = renderHook(() =>
        useBankNavigation({ channelCount: 8, totalTracks: 8 })
      );
      // Only 1 bank, already at it
      expect(result.current.canGoForward).toBe(false);
      act(() => result.current.goForward());
      expect(result.current.bankIndex).toBe(0);
    });

    it('goBack is no-op at first bank', () => {
      const { result } = renderHook(() =>
        useBankNavigation({ channelCount: 4, totalTracks: 20 })
      );
      act(() => result.current.goBack());
      expect(result.current.bankIndex).toBe(0);
    });

    it('goToBank jumps to specific bank', () => {
      const { result } = renderHook(() =>
        useBankNavigation({ channelCount: 4, totalTracks: 20 })
      );
      act(() => result.current.goToBank(3));
      expect(result.current.bankIndex).toBe(3);
    });

    it('goToBank clamps to valid range', () => {
      const { result } = renderHook(() =>
        useBankNavigation({ channelCount: 4, totalTracks: 20 })
      );
      act(() => result.current.goToBank(99));
      expect(result.current.bankIndex).toBe(4); // 20/4 = 5 banks, max index 4

      act(() => result.current.goToBank(-5));
      expect(result.current.bankIndex).toBe(0);
    });
  });

  // ===========================================================================
  // Prefetch ranges
  // ===========================================================================

  describe('prefetch', () => {
    it('includes adjacent banks in prefetch range', () => {
      const { result } = renderHook(() =>
        useBankNavigation({ channelCount: 8, totalTracks: 40 })
      );
      // Bank 0: tracks 1-8, desktop (8 channels) = 1 prefetch bank
      // prefetchStart = max(1, 1 - 8) = 1
      // prefetchEnd = min(40, 8 + 8) = 16
      expect(result.current.prefetchStart).toBeLessThanOrEqual(result.current.bankStart);
      expect(result.current.prefetchEnd).toBeGreaterThanOrEqual(result.current.bankEnd);
    });

    it('clamps prefetch to valid track range', () => {
      const { result } = renderHook(() =>
        useBankNavigation({ channelCount: 4, totalTracks: 8 })
      );
      expect(result.current.prefetchStart).toBeGreaterThanOrEqual(1);
      expect(result.current.prefetchEnd).toBeLessThanOrEqual(8);
    });
  });

  // ===========================================================================
  // Display string
  // ===========================================================================

  describe('bankDisplay', () => {
    it('shows range format', () => {
      const { result } = renderHook(() =>
        useBankNavigation({ channelCount: 8, totalTracks: 24 })
      );
      expect(result.current.bankDisplay).toBe('1-8 / 24');
    });

    it('shows single track format', () => {
      const { result } = renderHook(() =>
        useBankNavigation({ channelCount: 1, totalTracks: 5 })
      );
      expect(result.current.bankDisplay).toBe('1 / 5');
    });

    it('shows "No tracks" when empty', () => {
      const { result } = renderHook(() =>
        useBankNavigation({ channelCount: 8, totalTracks: 0 })
      );
      expect(result.current.bankDisplay).toBe('No tracks');
    });
  });

  // ===========================================================================
  // Persistence
  // ===========================================================================

  describe('localStorage persistence', () => {
    it('persists bank index', () => {
      const { result } = renderHook(() =>
        useBankNavigation({ channelCount: 4, totalTracks: 20 })
      );
      act(() => result.current.goForward());
      expect(localStorage.getItem('reamo-mixer-bank')).toBe('1');
    });

    it('restores bank from localStorage', () => {
      localStorage.setItem('reamo-mixer-bank', '2');
      const { result } = renderHook(() =>
        useBankNavigation({ channelCount: 4, totalTracks: 20 })
      );
      expect(result.current.bankIndex).toBe(2);
    });

    it('uses custom storageKey', () => {
      const { result } = renderHook(() =>
        useBankNavigation({ channelCount: 4, totalTracks: 20, storageKey: 'custom-key' })
      );
      act(() => result.current.goForward());
      expect(localStorage.getItem('custom-key')).toBe('1');
    });
  });
});
