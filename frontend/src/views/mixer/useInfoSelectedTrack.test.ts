/**
 * useInfoSelectedTrack Hook Tests
 *
 * The mixer's info bar renames, duplicates and deletes the track it shows.
 * It must keep showing the track the user picked when tracks are added or
 * removed around it, never whichever track slides into the same slot.
 */

import { describe, it, expect, beforeEach } from 'vitest';
import { renderHook, act } from '@testing-library/react';
import { useInfoSelectedTrack, INFO_SELECTED_STORAGE_KEY } from './useInfoSelectedTrack';
import type { SkeletonTrack } from '../../core/WebSocketTypes';

function skeleton(...guids: string[]): SkeletonTrack[] {
  return ['master', ...guids].map((g) => ({
    n: g, g, m: false, sl: null, sel: false, r: false, fd: 0, sc: 0, hc: 0, cl: false, ic: 0, fm: 0, c: 0,
  }));
}

describe('useInfoSelectedTrack', () => {
  beforeEach(() => localStorage.clear());

  it('stays on the picked track when a track is inserted above it', () => {
    const { result, rerender } = renderHook(({ s }) => useInfoSelectedTrack(s), {
      initialProps: { s: skeleton('{DRUMS}', '{VOX}') },
    });
    act(() => result.current.select(2));
    expect(result.current.selectedIdx).toBe(2);

    rerender({ s: skeleton('{NEW}', '{DRUMS}', '{VOX}') });
    expect(result.current.selectedIdx).toBe(3);
    expect(result.current.selectedGuid).toBe('{VOX}');
  });

  it('shows nothing once the picked track is deleted, rather than its neighbour', () => {
    const { result, rerender } = renderHook(({ s }) => useInfoSelectedTrack(s), {
      initialProps: { s: skeleton('{DRUMS}', '{VOX}', '{BASS}') },
    });
    act(() => result.current.select(2));
    rerender({ s: skeleton('{DRUMS}', '{BASS}') });
    expect(result.current.selectedIdx).toBeNull();
  });

  it('selects the master track', () => {
    const { result } = renderHook(() => useInfoSelectedTrack(skeleton('{DRUMS}')));
    act(() => result.current.select(0));
    expect(result.current.selectedIdx).toBe(0);
    expect(result.current.selectedGuid).toBe('master');
  });

  it('clears the selection', () => {
    const { result } = renderHook(() => useInfoSelectedTrack(skeleton('{DRUMS}')));
    act(() => result.current.select(1));
    act(() => result.current.select(null));
    expect(result.current.selectedIdx).toBeNull();
  });

  it('remembers the picked track across reloads, and waits for the track list', () => {
    const first = renderHook(() => useInfoSelectedTrack(skeleton('{DRUMS}', '{VOX}')));
    act(() => first.result.current.select(2));
    first.unmount();

    const { result, rerender } = renderHook(({ s }) => useInfoSelectedTrack(s), {
      initialProps: { s: [] as SkeletonTrack[] },
    });
    expect(result.current.selectedIdx).toBeNull();
    rerender({ s: skeleton('{NEW}', '{DRUMS}', '{VOX}') });
    expect(result.current.selectedIdx).toBe(3);
  });

  it('ignores a selection stored as a track number by older versions', () => {
    localStorage.setItem(INFO_SELECTED_STORAGE_KEY, '2');
    const { result } = renderHook(() => useInfoSelectedTrack(skeleton('{DRUMS}', '{VOX}')));
    expect(result.current.selectedIdx).toBeNull();
  });
});
