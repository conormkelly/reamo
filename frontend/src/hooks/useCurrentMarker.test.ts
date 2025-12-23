/**
 * Tests for useCurrentMarker hook - Marker selection logic
 *
 * These tests verify marker selection behavior:
 * - Selecting marker when playhead lands on marker position (Prev/Next navigation)
 * - Auto-advancing when playhead crosses markers during playback
 * - Respecting locked state during editing
 *
 * Note: REAPER's Prev/Next marker actions also stop at time selection
 * boundaries and region start/ends, so we test position matching rather
 * than assuming navigation always lands on a marker.
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { useReaperStore } from '../store';
import { useCurrentMarker } from './useCurrentMarker';
import type { Marker } from '../core/types';

// Helper to create test markers
function createTestMarkers(): Marker[] {
  return [
    { id: 1, name: 'Intro', position: 0, color: 0xff0000 },
    { id: 2, name: 'Verse 1', position: 10, color: 0x00ff00 },
    { id: 3, name: 'Chorus', position: 20, color: 0x0000ff },
    { id: 4, name: 'Verse 2', position: 30, color: 0xffff00 },
  ];
}

// Reset store to initial state
function resetStore(markers: Marker[] = createTestMarkers()) {
  useReaperStore.setState({
    markers,
    positionSeconds: 0,
    playState: 0, // stopped
    selectedMarkerId: null,
    isMarkerLocked: false,
  });
}

describe('useCurrentMarker', () => {
  beforeEach(() => {
    resetStore();
  });

  describe('marker selection when stopped (Prev/Next navigation)', () => {
    it('selects marker when playhead is at marker position on mount', () => {
      // Position starts at 0, which has marker 1
      const { result } = renderHook(() => useCurrentMarker());

      // Should auto-select marker 1 since we're at position 0
      expect(result.current.currentMarker).not.toBeNull();
      expect(result.current.currentMarker?.id).toBe(1);
      expect(result.current.currentMarker?.name).toBe('Intro');
    });

    it('selects marker when playhead moves to marker position', () => {
      // Start at position 5 (not at any marker)
      useReaperStore.setState({ positionSeconds: 5 });
      const { result } = renderHook(() => useCurrentMarker());

      // Initially no marker selected (position 5 is not at a marker)
      expect(result.current.currentMarker).toBeNull();

      // Simulate Prev/Next navigation landing on marker 2 (position 10)
      act(() => {
        useReaperStore.setState({ positionSeconds: 10 });
      });

      // Should select marker 2
      expect(result.current.currentMarker).not.toBeNull();
      expect(result.current.currentMarker?.id).toBe(2);
      expect(result.current.currentMarker?.name).toBe('Verse 1');
    });

    it('selects marker within epsilon tolerance', () => {
      // Start at position 5 (not at any marker)
      useReaperStore.setState({ positionSeconds: 5 });
      const { result } = renderHook(() => useCurrentMarker());

      // Move to slightly off marker position (within 10ms epsilon)
      act(() => {
        useReaperStore.setState({ positionSeconds: 10.005 });
      });

      // Should still select marker 2
      expect(result.current.currentMarker?.id).toBe(2);
    });

    it('keeps selection when position moves to non-marker position', () => {
      // Position starts at 0, which has marker 1
      const { result } = renderHook(() => useCurrentMarker());
      expect(result.current.currentMarker?.id).toBe(1);

      // Move to position between markers (e.g., at region boundary)
      act(() => {
        useReaperStore.setState({ positionSeconds: 15 });
      });

      // Should keep marker 1 selected (we don't clear selection when not at a marker)
      expect(result.current.currentMarker?.id).toBe(1);
    });

    it('updates selection when navigating to different marker', () => {
      const { result } = renderHook(() => useCurrentMarker());

      // First, go to marker 1
      act(() => {
        useReaperStore.setState({ positionSeconds: 0 });
      });
      expect(result.current.currentMarker?.id).toBe(1);

      // Then navigate to marker 3
      act(() => {
        useReaperStore.setState({ positionSeconds: 20 });
      });
      expect(result.current.currentMarker?.id).toBe(3);
      expect(result.current.currentMarker?.name).toBe('Chorus');
    });
  });

  describe('marker crossing during playback', () => {
    it('selects marker when playhead crosses it during playback', () => {
      const { result } = renderHook(() => useCurrentMarker());

      // Start playback at position 5 (between marker 1 and 2)
      act(() => {
        useReaperStore.setState({
          positionSeconds: 5,
          playState: 1, // playing
        });
      });

      // No marker should be selected yet (we're between markers)
      // Actually, with the fix, it might select marker 1 as the "active" one
      // Let's verify the crossing behavior

      // Advance to cross marker 2
      act(() => {
        useReaperStore.setState({ positionSeconds: 10.5 });
      });

      // Should select marker 2 (just crossed)
      expect(result.current.currentMarker?.id).toBe(2);
    });

    it('selects most recently crossed marker during continuous playback', () => {
      const { result } = renderHook(() => useCurrentMarker());

      // Start at position 5
      act(() => {
        useReaperStore.setState({
          positionSeconds: 5,
          playState: 1,
        });
      });

      // Cross marker 2
      act(() => {
        useReaperStore.setState({ positionSeconds: 15 });
      });
      expect(result.current.currentMarker?.id).toBe(2);

      // Cross marker 3
      act(() => {
        useReaperStore.setState({ positionSeconds: 25 });
      });
      expect(result.current.currentMarker?.id).toBe(3);
    });

    it('updates to active marker on seek during playback', () => {
      const { result } = renderHook(() => useCurrentMarker());

      // Start playing at position 5
      act(() => {
        useReaperStore.setState({
          positionSeconds: 5,
          playState: 1,
        });
      });

      // Seek backwards to position 22 (past marker 3)
      act(() => {
        useReaperStore.setState({ positionSeconds: 22 });
      });

      // Should select marker 3 (most recent marker before position)
      expect(result.current.currentMarker?.id).toBe(3);
    });
  });

  describe('locked state (during editing)', () => {
    it('does not update selection when locked', () => {
      const { result } = renderHook(() => useCurrentMarker());

      // Select marker 1 and lock
      act(() => {
        result.current.selectMarker(1);
      });
      expect(result.current.currentMarker?.id).toBe(1);
      expect(result.current.isLocked).toBe(true);

      // Try to navigate to marker 3
      act(() => {
        useReaperStore.setState({ positionSeconds: 20 });
      });

      // Should still show marker 1 (locked)
      expect(result.current.currentMarker?.id).toBe(1);
    });

    it('unlocks and allows updates after setLocked(false)', () => {
      const { result } = renderHook(() => useCurrentMarker());

      // Select and lock
      act(() => {
        result.current.selectMarker(1);
      });
      expect(result.current.isLocked).toBe(true);

      // Unlock
      act(() => {
        result.current.setLocked(false);
      });
      expect(result.current.isLocked).toBe(false);

      // Navigate should now work
      act(() => {
        useReaperStore.setState({ positionSeconds: 20 });
      });
      expect(result.current.currentMarker?.id).toBe(3);
    });
  });

  describe('selectMarker function', () => {
    it('manually selects a marker and locks auto-advance', () => {
      const { result } = renderHook(() => useCurrentMarker());

      act(() => {
        result.current.selectMarker(3);
      });

      expect(result.current.currentMarker?.id).toBe(3);
      expect(result.current.isLocked).toBe(true);
    });

    it('clears selection when passed null', () => {
      const { result } = renderHook(() => useCurrentMarker());

      // First select a marker
      act(() => {
        result.current.selectMarker(2);
      });
      expect(result.current.currentMarker?.id).toBe(2);

      // Clear selection
      act(() => {
        result.current.selectMarker(null);
      });
      expect(result.current.currentMarker).toBeNull();
    });
  });

  describe('edge cases', () => {
    it('handles empty markers array', () => {
      resetStore([]);
      const { result } = renderHook(() => useCurrentMarker());

      act(() => {
        useReaperStore.setState({ positionSeconds: 10 });
      });

      expect(result.current.currentMarker).toBeNull();
    });

    it('handles position at exactly 0', () => {
      const { result } = renderHook(() => useCurrentMarker());

      act(() => {
        useReaperStore.setState({ positionSeconds: 0 });
      });

      // Marker 1 is at position 0
      expect(result.current.currentMarker?.id).toBe(1);
    });

    it('handles position changes during recording', () => {
      const { result } = renderHook(() => useCurrentMarker());

      // playState 5 = recording
      act(() => {
        useReaperStore.setState({
          positionSeconds: 5,
          playState: 5,
        });
      });

      // Cross marker 2
      act(() => {
        useReaperStore.setState({ positionSeconds: 15 });
      });

      expect(result.current.currentMarker?.id).toBe(2);
    });
  });
});
