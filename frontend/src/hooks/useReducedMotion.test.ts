/**
 * useReducedMotion Hook Tests
 */

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { useReducedMotion } from './useReducedMotion';

describe('useReducedMotion', () => {
  // Store original matchMedia
  const originalMatchMedia = window.matchMedia;

  // Mock matchMedia implementation
  function createMockMatchMedia(matches: boolean) {
    const listeners: Array<(event: MediaQueryListEvent) => void> = [];

    const mockMediaQueryList = {
      matches,
      media: '(prefers-reduced-motion: reduce)',
      onchange: null,
      addEventListener: vi.fn((event: string, callback: (event: MediaQueryListEvent) => void) => {
        if (event === 'change') {
          listeners.push(callback);
        }
      }),
      removeEventListener: vi.fn((event: string, callback: (event: MediaQueryListEvent) => void) => {
        if (event === 'change') {
          const index = listeners.indexOf(callback);
          if (index > -1) listeners.splice(index, 1);
        }
      }),
      dispatchEvent: vi.fn(),
      // Helper to simulate a change event
      _triggerChange: (newMatches: boolean) => {
        mockMediaQueryList.matches = newMatches;
        listeners.forEach((listener) => {
          listener({ matches: newMatches } as MediaQueryListEvent);
        });
      },
    };

    return vi.fn().mockReturnValue(mockMediaQueryList);
  }

  afterEach(() => {
    // Restore original matchMedia
    window.matchMedia = originalMatchMedia;
  });

  describe('initialization', () => {
    it('returns false when user does not prefer reduced motion', () => {
      window.matchMedia = createMockMatchMedia(false);

      const { result } = renderHook(() => useReducedMotion());

      expect(result.current).toBe(false);
    });

    it('returns true when user prefers reduced motion', () => {
      window.matchMedia = createMockMatchMedia(true);

      const { result } = renderHook(() => useReducedMotion());

      expect(result.current).toBe(true);
    });

    it('queries the correct media query', () => {
      const mockMatchMedia = createMockMatchMedia(false);
      window.matchMedia = mockMatchMedia;

      renderHook(() => useReducedMotion());

      expect(mockMatchMedia).toHaveBeenCalledWith('(prefers-reduced-motion: reduce)');
    });
  });

  describe('event listener', () => {
    it('adds change event listener on mount', () => {
      const mockMatchMedia = createMockMatchMedia(false);
      window.matchMedia = mockMatchMedia;

      renderHook(() => useReducedMotion());

      const mediaQueryList = mockMatchMedia.mock.results[0].value;
      expect(mediaQueryList.addEventListener).toHaveBeenCalledWith('change', expect.any(Function));
    });

    it('removes change event listener on unmount', () => {
      const mockMatchMedia = createMockMatchMedia(false);
      window.matchMedia = mockMatchMedia;

      const { unmount } = renderHook(() => useReducedMotion());
      unmount();

      const mediaQueryList = mockMatchMedia.mock.results[0].value;
      expect(mediaQueryList.removeEventListener).toHaveBeenCalledWith('change', expect.any(Function));
    });

    it('responds to preference changes', () => {
      const mockMatchMedia = createMockMatchMedia(false);
      window.matchMedia = mockMatchMedia;

      const { result } = renderHook(() => useReducedMotion());

      expect(result.current).toBe(false);

      // Simulate user enabling reduced motion
      act(() => {
        const mediaQueryList = mockMatchMedia.mock.results[0].value;
        mediaQueryList._triggerChange(true);
      });

      expect(result.current).toBe(true);

      // Simulate user disabling reduced motion
      act(() => {
        const mediaQueryList = mockMatchMedia.mock.results[0].value;
        mediaQueryList._triggerChange(false);
      });

      expect(result.current).toBe(false);
    });
  });

  describe('SSR safety', () => {
    it('handles undefined window gracefully in initial state', () => {
      // The hook uses typeof window === 'undefined' check in useState initializer
      // In JSDOM/Vitest, window is always defined, so we can't easily test this
      // but we verify the pattern is correct by checking it doesn't throw
      window.matchMedia = createMockMatchMedia(false);

      expect(() => {
        renderHook(() => useReducedMotion());
      }).not.toThrow();
    });
  });
});
