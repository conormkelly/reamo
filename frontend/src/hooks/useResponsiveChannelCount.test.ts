/**
 * Tests for useResponsiveChannelCount — breakpoint-based channel calculation.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { useResponsiveChannelCount } from './useResponsiveChannelCount';

describe('useResponsiveChannelCount', () => {
  let originalInnerWidth: number;

  beforeEach(() => {
    originalInnerWidth = window.innerWidth;
  });

  afterEach(() => {
    Object.defineProperty(window, 'innerWidth', {
      value: originalInnerWidth,
      configurable: true,
    });
    vi.restoreAllMocks();
  });

  function setWindowWidth(width: number) {
    Object.defineProperty(window, 'innerWidth', {
      value: width,
      configurable: true,
    });
  }

  // ===========================================================================
  // Breakpoint channel counts
  // ===========================================================================

  describe('breakpoint channels', () => {
    it('returns 2 channels for narrow phones (<=400px)', () => {
      setWindowWidth(375);
      const { result } = renderHook(() => useResponsiveChannelCount());
      expect(result.current.channelCount).toBe(2);
    });

    it('returns 3 channels for wide phones (401-550px)', () => {
      setWindowWidth(500);
      const { result } = renderHook(() => useResponsiveChannelCount());
      expect(result.current.channelCount).toBe(3);
    });

    it('returns 4 channels for small tablets (551-700px)', () => {
      setWindowWidth(650);
      const { result } = renderHook(() => useResponsiveChannelCount());
      expect(result.current.channelCount).toBe(4);
    });

    it('returns 8 channels for wide desktop (>1200px)', () => {
      setWindowWidth(1440);
      const { result } = renderHook(() => useResponsiveChannelCount());
      expect(result.current.channelCount).toBe(8);
    });
  });

  // ===========================================================================
  // Master track reservation
  // ===========================================================================

  describe('master pinned', () => {
    it('reserves space for master track by default', () => {
      setWindowWidth(700);
      const withMaster = renderHook(() =>
        useResponsiveChannelCount({ masterPinned: true })
      );
      const withoutMaster = renderHook(() =>
        useResponsiveChannelCount({ masterPinned: false })
      );
      // Without master, more available width → more or equal channels
      expect(withoutMaster.result.current.channelCount).toBeGreaterThanOrEqual(
        withMaster.result.current.channelCount
      );
    });

    it('computes availableWidth subtracting master and padding', () => {
      setWindowWidth(1000);
      const { result } = renderHook(() =>
        useResponsiveChannelCount({ masterPinned: true })
      );
      // 1000 - 70 (master) - 32 (padding) = 898
      expect(result.current.availableWidth).toBe(898);
    });

    it('computes availableWidth without master reservation', () => {
      setWindowWidth(1000);
      const { result } = renderHook(() =>
        useResponsiveChannelCount({ masterPinned: false })
      );
      // 1000 - 0 (no master) - 32 (padding) = 968
      expect(result.current.availableWidth).toBe(968);
    });
  });

  // ===========================================================================
  // Minimum channel count
  // ===========================================================================

  describe('minimum channels', () => {
    it('never returns less than 2 channels', () => {
      setWindowWidth(200); // Very narrow
      const { result } = renderHook(() => useResponsiveChannelCount());
      expect(result.current.channelCount).toBeGreaterThanOrEqual(2);
    });
  });

  // ===========================================================================
  // Resize reactivity
  // ===========================================================================

  describe('resize', () => {
    it('updates on window resize', () => {
      setWindowWidth(1440);
      const { result } = renderHook(() => useResponsiveChannelCount());
      expect(result.current.channelCount).toBe(8);

      act(() => {
        setWindowWidth(375);
        window.dispatchEvent(new Event('resize'));
      });

      expect(result.current.channelCount).toBe(2);
    });
  });
});
